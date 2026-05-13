// Minimal WebM (Matroska subset) demuxer. Yields VP8 video frames in
// presentation order with PTS in nanoseconds.
//
// References:
//   * WebM container specification:
//       https://www.webmproject.org/docs/container/
//   * Matroska element IDs: https://www.matroska.org/technical/elements.html
//   * SimpleBlock layout:   https://www.matroska.org/technical/notes.html
//
// What we support:
//   * EBML header with DocType "webm" or "matroska".
//   * The first video track whose CodecID is "V_VP8".
//   * SimpleBlock and (uncompressed) Block elements inside Cluster.
//     Track-number lacing is "no lacing" only — per the WebM spec,
//     VP8 video MUST be unlaced, so this is not a real limitation.
//
// What we deliberately skip (out of scope for a VP8-only player):
//   * Audio tracks (Vorbis/Opus).
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
const int _idTracks = 0x1654AE6B;
const int _idTrackEntry = 0xAE;
const int _idTrackNumber = 0xD7;
const int _idTrackType = 0x83;
const int _idCodecId = 0x86;
const int _idVideo = 0xE0;
const int _idPixelWidth = 0xB0;
const int _idPixelHeight = 0xBA;
const int _idCluster = 0x1F43B675;
const int _idTimestamp = 0xE7; // a.k.a. Timecode (legacy)
const int _idSimpleBlock = 0xA3;
const int _idBlockGroup = 0xA0;
const int _idBlock = 0xA1;

const int _trackTypeVideo = 1;

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

/// Reads VP8 video frames from an in-memory WebM byte buffer.
///
/// This is intentionally a single-track, video-only demuxer. The first
/// V_VP8 track found is selected; everything else is ignored.
class WebmReader {
  WebmReader._({
    required this.bytes,
    required this.width,
    required this.height,
    required this.timestampScaleNanos,
    required int videoTrackNumber,
    required int firstClusterOffset,
    required int segmentEnd,
  })  : _videoTrack = videoTrackNumber,
        _segmentEnd = segmentEnd,
        _ebml = EbmlReader(bytes),
        _clusterOff = firstClusterOffset,
        _clusterEnd = 0,
        _clusterTimestamp = 0,
        _innerOff = 0;

  final Uint8List bytes;
  final EbmlReader _ebml;

  /// Pixel width and height of the selected video track.
  final int width;
  final int height;

  /// Multiplier (in nanoseconds) applied to per-cluster + per-block
  /// timestamps to get an absolute PTS in nanoseconds. WebM defaults
  /// this to 1,000,000 (= 1 ms granularity).
  final int timestampScaleNanos;

  final int _videoTrack;
  final int _segmentEnd;

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

    // 3. Walk top-level Segment children, find Info / Tracks, and stop
    //    at the first Cluster.
    int timestampScaleNanos = 1000000; // default: 1 ms.
    int? videoTrack;
    int width = 0, height = 0;
    int? firstClusterOff;
    int off = seg.payloadOffset;
    while (off < segmentEnd) {
      final el = r.readElement(off);
      if (el.id == _idCluster) {
        firstClusterOff = off;
        break;
      } else if (el.id == _idInfo) {
        for (final c in r.children(el)) {
          if (c.id == _idTimestampScale) {
            timestampScaleNanos = r.readUint(c);
          }
        }
      } else if (el.id == _idTracks) {
        for (final entry in r.children(el)) {
          if (entry.id != _idTrackEntry) continue;
          int? trkNum;
          int trkType = 0;
          String codec = '';
          int w = 0, h = 0;
          for (final f in r.children(entry)) {
            switch (f.id) {
              case _idTrackNumber:
                trkNum = r.readUint(f);
              case _idTrackType:
                trkType = r.readUint(f);
              case _idCodecId:
                codec = r.readString(f);
              case _idVideo:
                for (final v in r.children(f)) {
                  if (v.id == _idPixelWidth) w = r.readUint(v);
                  if (v.id == _idPixelHeight) h = r.readUint(v);
                }
            }
          }
          if (videoTrack == null &&
              trkType == _trackTypeVideo &&
              codec == 'V_VP8' &&
              trkNum != null) {
            videoTrack = trkNum;
            width = w;
            height = h;
          }
        }
      }
      off = el.end;
    }

    if (videoTrack == null) {
      throw const FormatException('WebM: no V_VP8 video track found');
    }
    if (firstClusterOff == null) {
      throw const FormatException('WebM: no Cluster found');
    }

    return WebmReader._(
      bytes: bytes,
      width: width,
      height: height,
      timestampScaleNanos: timestampScaleNanos,
      videoTrackNumber: videoTrack,
      firstClusterOffset: firstClusterOff,
      segmentEnd: segmentEnd,
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

      // First, find this cluster's Timestamp (must be the first child
      // per spec, but we don't rely on order).
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

  /// Parse a SimpleBlock element. Returns null if it doesn't belong to
  /// our selected video track. Throws on lacing.
  WebmFrame? _parseSimpleBlock(EbmlElement el) {
    final int payOff = el.payloadOffset;
    final track = _ebml.readVint(payOff, stripMarker: true);
    if (track.value != _videoTrack) return null;
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
    final int dataLen = el.end - dataOff;
    final Uint8List frame = Uint8List.sublistView(bytes, dataOff, el.end);
    final int pts = (_clusterTimestamp + delta) * timestampScaleNanos;
    // Touch dataLen to silence unused-local lint without altering behaviour.
    assert(dataLen == frame.length);
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
    // Block payload layout matches SimpleBlock except the high bits of
    // the flags byte (keyframe / discardable) are reserved. Reuse the
    // same parser — keyframe bit is forced to false on this path; the
    // VP8 frame tag is the source of truth anyway.
    final int payOff = block.payloadOffset;
    final track = _ebml.readVint(payOff, stripMarker: true);
    if (track.value != _videoTrack) return null;
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
