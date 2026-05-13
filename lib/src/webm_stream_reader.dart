// Incremental WebM reader for live / chunked input. Caller pushes bytes
// in any size with [addBytes]; the reader buffers internally and yields
// frames as soon as enough data is available.
//
// Memory: the buffer grows monotonically. Use this for streams up to a
// few hundred MB or for short-lived live feeds. For unbounded streams,
// add a compaction step that drops bytes before [bufferRetainOffset].
//
// API:
//   final r = WebmStreamReader();
//   r.addBytes(chunk);
//   if (r.tryParseHeader()) { ... r.video, r.tracks ... }
//   while ((final frame = r.nextFrame()) != null) { decoder.decodeBytes(frame.data); }

import 'dart:typed_data';

import 'ebml.dart';
import 'webm_reader.dart' show WebmFrame, WebmTrack;

// EBML element IDs (mirror webm_reader.dart).
const int _idEbml = 0x1A45DFA3;
const int _idDocType = 0x4282;
const int _idSegment = 0x18538067;
const int _idInfo = 0x1549A966;
const int _idTimestampScale = 0x2AD7B1;
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
const int _idTimestamp = 0xE7;
const int _idSimpleBlock = 0xA3;
const int _idBlockGroup = 0xA0;
const int _idBlock = 0xA1;

/// Stateful, push-driven WebM demuxer.
class WebmStreamReader {
  Uint8List _buf = Uint8List(0);
  int _len = 0; // number of valid bytes in _buf

  /// Top-level scan cursor (absolute offset in the byte stream).
  int _topCursor = 0;

  /// End offset of the Segment element, once known.
  int _segmentEnd = -1;

  /// True once Tracks has been parsed and a V_VP8 video track found.
  bool _headerDone = false;

  /// True once we've called [endOfStream].
  bool _ended = false;

  // Public header fields (only valid once [headerReady] is true).
  List<WebmTrack> tracks = const <WebmTrack>[];
  late WebmTrack video;
  int timestampScaleNanos = 1000000;
  int? durationNanos;

  /// Cluster iteration state.
  int _clusterEnd = 0;
  int _clusterTimestamp = 0;
  int _innerOff = 0;

  bool get headerReady => _headerDone;

  /// Smallest offset still required by the parser; bytes before this
  /// could be safely dropped if we wanted to compact the buffer.
  int get bufferRetainOffset => _innerOff < _topCursor ? _innerOff : _topCursor;

  /// Total bytes pushed so far.
  int get bytesBuffered => _len;

  /// Append bytes to the internal buffer.
  void addBytes(List<int> chunk) {
    if (_ended) {
      throw StateError('WebmStreamReader: addBytes after endOfStream');
    }
    final int needed = _len + chunk.length;
    if (needed > _buf.length) {
      int cap = _buf.isEmpty ? 64 * 1024 : _buf.length;
      while (cap < needed) {
        cap *= 2;
      }
      final next = Uint8List(cap);
      next.setRange(0, _len, _buf);
      _buf = next;
    }
    if (chunk is Uint8List) {
      _buf.setRange(_len, _len + chunk.length, chunk);
    } else {
      for (int i = 0; i < chunk.length; i++) {
        _buf[_len + i] = chunk[i] & 0xFF;
      }
    }
    _len += chunk.length;
  }

  /// Signal that no more bytes will arrive. Subsequent [nextFrame]
  /// calls will return null forever once the buffered tail is drained.
  void endOfStream() {
    _ended = true;
  }

  /// Try to parse the EBML / Segment / Tracks header. Returns true if
  /// the header is now ready (or was already), false if not enough
  /// bytes have been buffered yet.
  ///
  /// Throws [FormatException] if the input is definitely not WebM.
  bool tryParseHeader() {
    if (_headerDone) return true;
    final r = EbmlReader(_view);

    // 1. EBML header.
    final ebml = r.tryReadElement(0);
    if (ebml == null) return false;
    if (ebml.id != _idEbml) {
      throw const FormatException('WebM stream: missing EBML header');
    }
    String docType = '';
    for (final c in r.children(ebml)) {
      if (c.id == _idDocType) docType = r.readString(c);
    }
    if (docType != 'webm' && docType != 'matroska') {
      throw FormatException('WebM stream: unsupported DocType "$docType"');
    }

    // 2. Segment header — we need just the (id, size), payload comes
    //    in over time. tryReadElement requires the FULL payload, which
    //    for Segment is the whole file — so use a custom path that
    //    only requires the header VINTs.
    final segHdrOff = ebml.end;
    final hdr = _peekElementHeader(r, segHdrOff);
    if (hdr == null) return false;
    if (hdr.id != _idSegment) {
      throw const FormatException('WebM stream: missing Segment');
    }
    _segmentEnd = hdr.payloadOffset + hdr.size;
    _topCursor = hdr.payloadOffset;

    // 3. Walk Segment children until we have a complete Tracks element.
    //    We scan past clusters / cues / etc. that arrive early.
    final List<WebmTrack> trks = <WebmTrack>[];
    int cursor = _topCursor;
    int? scaleNs;
    int? durScale;
    bool tracksSeen = false;
    while (cursor < _segmentEnd) {
      final el = r.tryReadElement(cursor);
      if (el == null) break;
      switch (el.id) {
        case _idInfo:
          for (final c in r.children(el)) {
            if (c.id == _idTimestampScale) scaleNs = r.readUint(c);
            if (c.id == _idDuration) durScale = r.readFloat(c).round();
          }
        case _idTracks:
          for (final entry in r.children(el)) {
            if (entry.id != _idTrackEntry) continue;
            trks.add(_parseTrackEntry(r, entry));
          }
          tracksSeen = true;
        case _idCluster:
          // Stop — header is done if we already saw Tracks; otherwise
          // this is malformed (Tracks must precede Clusters).
          if (!tracksSeen) {
            throw const FormatException('WebM stream: Cluster before Tracks');
          }
        // Other elements (SeekHead, Cues, Tags, Chapters) ignored here.
      }
      cursor = el.end;
      if (tracksSeen && el.id == _idTracks) break;
      if (el.id == _idCluster) break;
    }

    if (!tracksSeen) return false; // need more bytes for Tracks.

    WebmTrack? vid;
    for (final t in trks) {
      if (t.isVideo && t.isVp8) {
        vid = t;
        break;
      }
    }
    if (vid == null) {
      throw const FormatException('WebM stream: no V_VP8 video track found');
    }
    tracks = List<WebmTrack>.unmodifiable(trks);
    video = vid;
    timestampScaleNanos = scaleNs ?? 1000000;
    durationNanos = durScale == null ? null : durScale * timestampScaleNanos;
    _topCursor = cursor;
    _headerDone = true;
    return true;
  }

  /// Yield the next VP8 video frame, or null if not enough bytes have
  /// been buffered yet (or end-of-stream has been reached).
  WebmFrame? nextFrame() {
    if (!_headerDone && !tryParseHeader()) return null;
    final r = EbmlReader(_view);

    while (true) {
      // Consume blocks inside the currently-open cluster.
      if (_innerOff < _clusterEnd) {
        final el = r.tryReadElement(_innerOff);
        if (el == null) return null; // wait for more bytes
        _innerOff = el.end;
        if (el.id == _idSimpleBlock) {
          final f = _parseSimpleBlock(r, el);
          if (f != null) return f;
        } else if (el.id == _idBlockGroup) {
          final f = _parseBlockGroup(r, el);
          if (f != null) return f;
        }
        continue;
      }

      // Open the next top-level element.
      if (_topCursor >= _segmentEnd) return null;
      final el = r.tryReadElement(_topCursor);
      if (el == null) return null;
      _topCursor = el.end;
      if (el.id != _idCluster) continue;
      _clusterEnd = el.end;
      _innerOff = el.payloadOffset;
      _clusterTimestamp = 0;
      // Find this cluster's Timestamp.
      int peek = _innerOff;
      while (peek < _clusterEnd) {
        final c = r.readElement(peek);
        if (c.id == _idTimestamp) {
          _clusterTimestamp = r.readUint(c);
          break;
        }
        peek = c.end;
      }
    }
  }

  Uint8List get _view => Uint8List.sublistView(_buf, 0, _len);

  WebmFrame? _parseSimpleBlock(EbmlReader r, EbmlElement el) {
    final int payOff = el.payloadOffset;
    final track = r.readVint(payOff, stripMarker: true);
    if (track.value != video.number) return null;
    final int hdr = payOff + track.length;
    final int rawDelta = (r.bytes[hdr] << 8) | r.bytes[hdr + 1];
    final int delta = rawDelta >= 0x8000 ? rawDelta - 0x10000 : rawDelta;
    final int flags = r.bytes[hdr + 2];
    final bool keyframe = (flags & 0x80) != 0;
    if (((flags >> 1) & 0x03) != 0) {
      throw const FormatException(
          'WebM stream: laced SimpleBlock not supported');
    }
    final int dataOff = hdr + 3;
    final Uint8List frame = Uint8List.sublistView(r.bytes, dataOff, el.end);
    return WebmFrame(
      ptsNanos: (_clusterTimestamp + delta) * timestampScaleNanos,
      data: frame,
      isKeyFrame: keyframe,
    );
  }

  WebmFrame? _parseBlockGroup(EbmlReader r, EbmlElement el) {
    EbmlElement? block;
    for (final c in r.children(el)) {
      if (c.id == _idBlock) {
        block = c;
        break;
      }
    }
    if (block == null) return null;
    final int payOff = block.payloadOffset;
    final track = r.readVint(payOff, stripMarker: true);
    if (track.value != video.number) return null;
    final int hdr = payOff + track.length;
    final int rawDelta = (r.bytes[hdr] << 8) | r.bytes[hdr + 1];
    final int delta = rawDelta >= 0x8000 ? rawDelta - 0x10000 : rawDelta;
    final int flags = r.bytes[hdr + 2];
    if (((flags >> 1) & 0x03) != 0) {
      throw const FormatException('WebM stream: laced Block not supported');
    }
    final int dataOff = hdr + 3;
    final Uint8List frame = Uint8List.sublistView(r.bytes, dataOff, block.end);
    return WebmFrame(
      ptsNanos: (_clusterTimestamp + delta) * timestampScaleNanos,
      data: frame,
      isKeyFrame: false,
    );
  }
}

/// Like [EbmlReader.tryReadElement] but only requires the (id, size)
/// header to be present — does NOT require the payload to be buffered.
/// Returns the element with the size field set even if the payload has
/// not arrived yet. Used for Segment, whose payload is the whole file.
EbmlElement? _peekElementHeader(EbmlReader r, int offset) {
  if (offset >= r.bytes.length) return null;
  final int first = r.bytes[offset];
  if (first == 0) {
    throw const FormatException('EBML: vint with no length marker');
  }
  int idLen = 1;
  int mask = 0x80;
  while ((first & mask) == 0) {
    idLen++;
    mask >>= 1;
  }
  if (offset + idLen > r.bytes.length) return null;
  final int sizeOff = offset + idLen;
  if (sizeOff >= r.bytes.length) return null;
  final int sFirst = r.bytes[sizeOff];
  if (sFirst == 0) {
    throw const FormatException('EBML: vint with no length marker');
  }
  int sLen = 1;
  int sMask = 0x80;
  while ((sFirst & sMask) == 0) {
    sLen++;
    sMask >>= 1;
  }
  if (sizeOff + sLen > r.bytes.length) return null;
  // Decode without stripping for the ID (already includes marker bits).
  int idVal = first;
  for (int i = 1; i < idLen; i++) {
    idVal = (idVal << 8) | r.bytes[offset + i];
  }
  // Strip marker for size.
  int sizeVal = sFirst & (sMask - 1);
  for (int i = 1; i < sLen; i++) {
    sizeVal = (sizeVal << 8) | r.bytes[sizeOff + i];
  }
  return EbmlElement(idVal, sizeVal, sizeOff + sLen);
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
