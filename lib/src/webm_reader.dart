// Minimal WebM (Matroska subset) demuxer. Yields VP8 video frames in
// presentation order with PTS in nanoseconds, with optional Cues-based
// seeking.
//
// References:
//   * WebM container specification:
//       https://www.webmproject.org/docs/container/
//   * Matroska element IDs: https://www.matroska.org/technical/elements.html
//   * SimpleBlock layout:   https://www.matroska.org/technical/notes.html
//
// What we support:
//   * EBML header with DocType "webm" or "matroska".
//   * Track enumeration (audio + video). The first V_VP8 track is the
//     default selection used by [nextFrame], but [tracks] exposes
//     everything for inspection.
//   * SimpleBlock and (uncompressed) Block elements inside Cluster.
//   * Optional Cues index — when present, [seekToTime] jumps directly
//     to the cluster containing the requested timestamp without a
//     linear scan.
//   * Segment Duration + per-track DefaultDuration (frame rate).
//
// What we deliberately skip (out of scope for a VP8-only player):
//   * Audio decoding (Vorbis/Opus). Audio tracks are *listed*, not
//     decoded.
//   * VP9, AV1.
//   * Encryption (CONTENT_ENC_*).
//   * Lacing (Xiph/EBML/fixed).
//   * Streaming / unknown-size segments.

import 'dart:typed_data';

import 'ebml.dart';

// EBML element IDs (kept in their on-disk "with marker bit" form).
const int _idEbml = 0x1A45DFA3;
const int _idDocType = 0x4282;
const int _idSegment = 0x18538067;
const int _idInfo = 0x1549A966;
const int _idTimestampScale = 0x2AD7B1; // a.k.a. TimecodeScale (legacy)
const int _idDuration = 0x4489;
const int _idTracks = 0x1654AE6B;
const int _idTrackEntry = 0xAE;
const int _idTrackNumber = 0xD7;
const int _idTrackType = 0x83;
const int _idCodecId = 0x86;
const int _idDefaultDuration = 0x23E383;
const int _idVideo = 0xE0;
const int _idAudio = 0xE1;
const int _idPixelWidth = 0xB0;
const int _idPixelHeight = 0xBA;
const int _idChannels = 0x9F;
const int _idSamplingFrequency = 0xB5;
const int _idCluster = 0x1F43B675;
const int _idTimestamp = 0xE7; // a.k.a. Timecode (legacy)
const int _idSimpleBlock = 0xA3;
const int _idBlockGroup = 0xA0;
const int _idBlock = 0xA1;
const int _idCues = 0x1C53BB6B;
const int _idCuePoint = 0xBB;
const int _idCueTime = 0xB3;
const int _idCueTrackPositions = 0xB7;
const int _idCueClusterPosition = 0xF1;

const int trackTypeVideo = 1;
const int trackTypeAudio = 2;
const int trackTypeSubtitle = 17;

/// One demuxed VP8 video frame.
class WebmFrame {
  WebmFrame({
    required this.ptsNanos,
    required this.data,
    required this.isKeyFrame,
  });

  /// Presentation timestamp in nanoseconds.
  final int ptsNanos;

  /// Compressed VP8 payload (zero-copy view into the source buffer).
  final Uint8List data;

  /// True if the SimpleBlock keyframe flag was set. Always false for the
  /// non-SimpleBlock path (Block inside BlockGroup); decoders can still
  /// determine keyframe-ness from the VP8 frame tag.
  final bool isKeyFrame;
}

/// Parsed metadata for one Matroska track. Includes both video and
/// audio tracks; audio is included for completeness (and so playback
/// pipelines can detect that they need an audio decoder), but this
/// demuxer never *decodes* audio.
class WebmTrack {
  WebmTrack({
    required this.number,
    required this.type,
    required this.codecId,
    this.width = 0,
    this.height = 0,
    this.channels = 0,
    this.samplingHz = 0.0,
    this.defaultFrameDurationNanos,
  });

  /// Matroska TrackNumber (1-based, dense).
  final int number;

  /// Matroska TrackType (1=video, 2=audio, 17=subtitle, ...).
  final int type;

  /// Matroska CodecID (e.g. "V_VP8", "V_VP9", "A_VORBIS", "A_OPUS").
  final String codecId;

  /// Video dimensions, or 0 for non-video tracks.
  final int width;
  final int height;

  /// Audio channel count and sampling frequency, or 0 for non-audio.
  final int channels;
  final double samplingHz;

  /// DefaultDuration (nanoseconds per frame) if the muxer wrote one.
  /// For video, this is 1/fps in ns (e.g. ~41.6M for 24 fps).
  final int? defaultFrameDurationNanos;

  bool get isVideo => type == trackTypeVideo;
  bool get isAudio => type == trackTypeAudio;
  bool get isVp8 => codecId == 'V_VP8';
}

/// One entry from the Cues index: a (timestamp, cluster offset) pair
/// for the seekable track.
class _CuePoint {
  _CuePoint(this.timestamp, this.clusterAbsOffset);
  final int timestamp; // in TimestampScale units
  final int clusterAbsOffset; // absolute byte offset of the Cluster
}

/// Reads VP8 video frames from an in-memory WebM byte buffer.
class WebmReader {
  WebmReader._({
    required this.bytes,
    required this.timestampScaleNanos,
    required this.tracks,
    required WebmTrack videoTrack,
    required this.durationNanos,
    required int firstClusterOffset,
    required int segmentEnd,
    required List<_CuePoint> cues,
  })  : video = videoTrack,
        _segmentEnd = segmentEnd,
        _ebml = EbmlReader(bytes),
        _firstClusterOff = firstClusterOffset,
        _clusterOff = firstClusterOffset,
        _clusterEnd = 0,
        _clusterTimestamp = 0,
        _innerOff = 0,
        _cues = cues;

  final Uint8List bytes;
  final EbmlReader _ebml;

  /// All tracks declared in the Tracks element (audio + video + ...).
  final List<WebmTrack> tracks;

  /// The selected V_VP8 video track.
  final WebmTrack video;

  /// Multiplier (in nanoseconds) applied to per-cluster + per-block
  /// timestamps to get an absolute PTS in nanoseconds. WebM defaults
  /// this to 1,000,000 (= 1 ms granularity).
  final int timestampScaleNanos;

  /// Total duration in nanoseconds, or null if the muxer didn't write
  /// a Segment Duration field.
  final int? durationNanos;

  /// Pixel width of the selected video track.
  int get width => video.width;

  /// Pixel height of the selected video track.
  int get height => video.height;

  /// Frame rate in Hz, derived from the video track's DefaultDuration,
  /// or null if unknown. (Inverse of `defaultFrameDurationNanos`.)
  double? get frameRate {
    final d = video.defaultFrameDurationNanos;
    if (d == null || d <= 0) return null;
    return 1e9 / d;
  }

  final int _segmentEnd;
  final int _firstClusterOff;
  final List<_CuePoint> _cues;

  /// True if a Cues index was present and useful for seeking.
  bool get hasCues => _cues.isNotEmpty;

  // Iteration state.
  int _clusterOff; // start offset of next Cluster header to parse
  int _clusterEnd; // end offset of the currently-open Cluster
  int _clusterTimestamp; // current Cluster's Timestamp field (in scale units)
  int _innerOff; // current offset inside the open Cluster

  /// Parse a WebM byte buffer and position the reader at the first frame.
  /// Throws [FormatException] for non-WebM input or VP8-track-not-found.
  factory WebmReader(Uint8List bytes) {
    final r = EbmlReader(bytes);

    // 1. EBML header, verify DocType.
    final ebml = r.readElement(0);
    if (ebml.id != _idEbml) {
      throw const FormatException('WebM: missing EBML header');
    }
    String docType = '';
    for (final c in r.children(ebml)) {
      if (c.id == _idDocType) docType = r.readString(c);
    }
    if (docType != 'webm' && docType != 'matroska') {
      throw FormatException('WebM: unsupported DocType "$docType"');
    }

    // 2. Locate the Segment.
    final seg = r.readElement(ebml.end);
    if (seg.id != _idSegment) {
      throw const FormatException('WebM: missing Segment after EBML header');
    }
    final int segmentEnd = seg.end;
    final int segmentPayloadStart = seg.payloadOffset;

    // 3. Walk ALL top-level Segment children. We need to find Info,
    //    Tracks, Cues, and the first Cluster. We scan past clusters
    //    (their size is known, so this is O(num-clusters), not bytes).
    int timestampScaleNanos = 1000000; // default: 1 ms.
    int? durationScaleUnits;
    int? firstClusterOff;
    final List<WebmTrack> tracks = <WebmTrack>[];
    final List<_CuePoint> cues = <_CuePoint>[];

    int off = segmentPayloadStart;
    while (off < segmentEnd) {
      final el = r.readElement(off);
      switch (el.id) {
        case _idCluster:
          firstClusterOff ??= off;
        case _idInfo:
          for (final c in r.children(el)) {
            if (c.id == _idTimestampScale) {
              timestampScaleNanos = r.readUint(c);
            } else if (c.id == _idDuration) {
              // Duration is a float in TimestampScale units.
              durationScaleUnits = r.readFloat(c).round();
            }
          }
        case _idTracks:
          for (final entry in r.children(el)) {
            if (entry.id != _idTrackEntry) continue;
            tracks.add(_parseTrackEntry(r, entry));
          }
        case _idCues:
          _parseCues(r, el, cues);
      }
      off = el.end;
    }

    // 4. Pick the first V_VP8 video track.
    WebmTrack? videoTrack;
    for (final t in tracks) {
      if (t.isVideo && t.isVp8) {
        videoTrack = t;
        break;
      }
    }
    if (videoTrack == null) {
      throw const FormatException('WebM: no V_VP8 video track found');
    }
    if (firstClusterOff == null) {
      throw const FormatException('WebM: no Cluster found');
    }

    // 5. Filter Cues to those that name the selected video track. Cues
    //    that omit CueTrack are kept (they apply to all tracks).
    // We currently parse all Cues regardless of CueTrack — for typical
    // WebM files there's exactly one video track and Cues are aligned
    // to its keyframes.
    // CueClusterPosition is segment-relative; convert to absolute now.
    final List<_CuePoint> absCues = [
      for (final c in cues)
        _CuePoint(c.timestamp, segmentPayloadStart + c.clusterAbsOffset),
    ];
    absCues.sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final int? durationNanos = durationScaleUnits == null
        ? null
        : durationScaleUnits * timestampScaleNanos;

    return WebmReader._(
      bytes: bytes,
      timestampScaleNanos: timestampScaleNanos,
      tracks: List<WebmTrack>.unmodifiable(tracks),
      videoTrack: videoTrack,
      durationNanos: durationNanos,
      firstClusterOffset: firstClusterOff,
      segmentEnd: segmentEnd,
      cues: absCues,
    );
  }

  /// Yields the next VP8 frame, or null at end-of-stream.
  WebmFrame? nextFrame() {
    while (true) {
      // If we're inside a cluster, try to pull the next block.
      if (_innerOff < _clusterEnd) {
        final el = _ebml.readElement(_innerOff);
        _innerOff = el.end;
        if (el.id == _idSimpleBlock) {
          final f = _parseSimpleBlock(el);
          if (f != null) return f;
        } else if (el.id == _idBlockGroup) {
          final f = _parseBlockGroup(el);
          if (f != null) return f;
        }
        // Other element kinds (PrevSize, etc.) ignored.
        continue;
      }

      // Need to open the next cluster.
      if (_clusterOff >= _segmentEnd) return null;
      final cluster = _ebml.readElement(_clusterOff);
      _clusterOff = cluster.end;
      if (cluster.id != _idCluster) {
        // Skip foreign top-level elements (Cues, SeekHead, Tags, ...).
        continue;
      }
      _clusterEnd = cluster.end;
      _innerOff = cluster.payloadOffset;

      // Read this cluster's Timestamp (must be the first child per
      // spec, but we don't rely on order).
      _clusterTimestamp = 0;
      int peek = _innerOff;
      while (peek < _clusterEnd) {
        final c = _ebml.readElement(peek);
        if (c.id == _idTimestamp) {
          _clusterTimestamp = _ebml.readUint(c);
          break;
        }
        peek = c.end;
      }
    }
  }

  /// Reset iteration to the start of the first Cluster. Useful as the
  /// fallback when [seekToTime] has nowhere better to land.
  void rewind() {
    _clusterOff = _firstClusterOff;
    _clusterEnd = 0;
    _innerOff = 0;
    _clusterTimestamp = 0;
  }

  /// Reposition the reader to the Cluster containing the largest
  /// Cues entry whose timestamp is `<= targetNanos`. The next call to
  /// [nextFrame] will return the first SimpleBlock in that Cluster
  /// (which, if Cues are aligned to keyframes — as ffmpeg / libwebm
  /// always do — will be a keyframe).
  ///
  /// If no Cues are available, this falls back to a linear scan from
  /// the start of the file.
  ///
  /// Returns the cluster timestamp (nanoseconds) we landed on, or null
  /// if the request is past end-of-stream.
  int? seekToTime(int targetNanos) {
    if (targetNanos < 0) targetNanos = 0;
    if (_cues.isNotEmpty) {
      final int target = targetNanos ~/ timestampScaleNanos;
      // Binary search for the rightmost cue with timestamp <= target.
      int lo = 0, hi = _cues.length - 1, ans = 0;
      while (lo <= hi) {
        final mid = (lo + hi) >> 1;
        if (_cues[mid].timestamp <= target) {
          ans = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      final cue = _cues[ans];
      _clusterOff = cue.clusterAbsOffset;
      _clusterEnd = 0;
      _innerOff = 0;
      _clusterTimestamp = 0;
      return cue.timestamp * timestampScaleNanos;
    }

    // No Cues — linear scan. Walk from the first cluster, peek each
    // cluster's Timestamp, and stop on the latest one whose start is
    // <= target.
    final int target = targetNanos ~/ timestampScaleNanos;
    int candidateOff = _firstClusterOff;
    int candidateTs = -1;
    int probe = _firstClusterOff;
    while (probe < _segmentEnd) {
      final el = _ebml.readElement(probe);
      if (el.id == _idCluster) {
        // Find this cluster's Timestamp.
        int ts = 0;
        int peek = el.payloadOffset;
        while (peek < el.end) {
          final c = _ebml.readElement(peek);
          if (c.id == _idTimestamp) {
            ts = _ebml.readUint(c);
            break;
          }
          peek = c.end;
        }
        if (ts <= target) {
          candidateOff = probe;
          candidateTs = ts;
        } else {
          break;
        }
      }
      probe = el.end;
    }
    _clusterOff = candidateOff;
    _clusterEnd = 0;
    _innerOff = 0;
    _clusterTimestamp = 0;
    return candidateTs < 0 ? null : candidateTs * timestampScaleNanos;
  }

  /// Parse a SimpleBlock element. Returns null if it doesn't belong to
  /// our selected video track. Throws on lacing.
  WebmFrame? _parseSimpleBlock(EbmlElement el) {
    final int payOff = el.payloadOffset;
    final track = _ebml.readVint(payOff, stripMarker: true);
    if (track.value != video.number) return null;
    final int hdr = payOff + track.length;
    // 2-byte signed timestamp delta + 1-byte flags.
    final int rawDelta = (bytes[hdr] << 8) | bytes[hdr + 1];
    final int delta = rawDelta >= 0x8000 ? rawDelta - 0x10000 : rawDelta;
    final int flags = bytes[hdr + 2];
    final bool keyframe = (flags & 0x80) != 0;
    final int lacing = (flags >> 1) & 0x03;
    if (lacing != 0) {
      throw const FormatException(
          'WebM: laced SimpleBlock not supported (VP8 must be unlaced)');
    }
    final int dataOff = hdr + 3;
    final Uint8List frame = Uint8List.sublistView(bytes, dataOff, el.end);
    final int pts = (_clusterTimestamp + delta) * timestampScaleNanos;
    return WebmFrame(ptsNanos: pts, data: frame, isKeyFrame: keyframe);
  }

  /// Parse a BlockGroup wrapper containing a single Block element.
  WebmFrame? _parseBlockGroup(EbmlElement el) {
    EbmlElement? block;
    for (final c in _ebml.children(el)) {
      if (c.id == _idBlock) {
        block = c;
        break;
      }
    }
    if (block == null) return null;
    final int payOff = block.payloadOffset;
    final track = _ebml.readVint(payOff, stripMarker: true);
    if (track.value != video.number) return null;
    final int hdr = payOff + track.length;
    final int rawDelta = (bytes[hdr] << 8) | bytes[hdr + 1];
    final int delta = rawDelta >= 0x8000 ? rawDelta - 0x10000 : rawDelta;
    final int flags = bytes[hdr + 2];
    final int lacing = (flags >> 1) & 0x03;
    if (lacing != 0) {
      throw const FormatException(
          'WebM: laced Block not supported (VP8 must be unlaced)');
    }
    final int dataOff = hdr + 3;
    final Uint8List frame = Uint8List.sublistView(bytes, dataOff, block.end);
    final int pts = (_clusterTimestamp + delta) * timestampScaleNanos;
    return WebmFrame(ptsNanos: pts, data: frame, isKeyFrame: false);
  }
}

WebmTrack _parseTrackEntry(EbmlReader r, EbmlElement entry) {
  int trkNum = 0;
  int trkType = 0;
  String codec = '';
  int w = 0, h = 0;
  int channels = 0;
  double samplingHz = 0.0;
  int? defaultDur;
  for (final f in r.children(entry)) {
    switch (f.id) {
      case _idTrackNumber:
        trkNum = r.readUint(f);
      case _idTrackType:
        trkType = r.readUint(f);
      case _idCodecId:
        codec = r.readString(f);
      case _idDefaultDuration:
        defaultDur = r.readUint(f);
      case _idVideo:
        for (final v in r.children(f)) {
          if (v.id == _idPixelWidth) w = r.readUint(v);
          if (v.id == _idPixelHeight) h = r.readUint(v);
        }
      case _idAudio:
        for (final a in r.children(f)) {
          if (a.id == _idChannels) channels = r.readUint(a);
          if (a.id == _idSamplingFrequency) samplingHz = r.readFloat(a);
        }
    }
  }
  return WebmTrack(
    number: trkNum,
    type: trkType,
    codecId: codec,
    width: w,
    height: h,
    channels: channels,
    samplingHz: samplingHz,
    defaultFrameDurationNanos: defaultDur,
  );
}

void _parseCues(EbmlReader r, EbmlElement cuesEl, List<_CuePoint> out) {
  for (final pt in r.children(cuesEl)) {
    if (pt.id != _idCuePoint) continue;
    int? time;
    int? clusterPos;
    for (final f in r.children(pt)) {
      if (f.id == _idCueTime) {
        time = r.readUint(f);
      } else if (f.id == _idCueTrackPositions) {
        for (final tp in r.children(f)) {
          if (tp.id == _idCueClusterPosition) clusterPos = r.readUint(tp);
          // CueTrack ignored for now (single video track assumption).
        }
      }
    }
    if (time != null && clusterPos != null) {
      // CueClusterPosition is Segment-payload-relative; the WebmReader
      // constructor converts to absolute before storing.
      out.add(_CuePoint(time, clusterPos));
    }
  }
}
