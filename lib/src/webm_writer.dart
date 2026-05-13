// Minimal WebM (Matroska subset) writer for VP8 video. The output is a
// valid .webm file readable by Chrome, ffmpeg, libvpx's vpxdec, mpv,
// and the [WebmReader] in this package.
//
// Design choices:
//   * Definite-size EBML — every element knows its length; no
//     unknown-size streamable segments.
//   * One Cluster per keyframe. The cluster timestamp equals the
//     keyframe's absolute timestamp; subsequent inter frames within
//     the cluster are written as signed int16 deltas (fits ±32 s at
//     the default 1 ms TimestampScale, which is well beyond any
//     reasonable keyframe interval).
//   * SimpleBlock for every frame (no BlockGroup wrapping). VP8 has
//     no B-frames so we never need ReferenceBlock.
//   * Cues are emitted at the end of the file, one entry per Cluster
//     (i.e. one entry per keyframe).
//   * TimestampScale = 1,000,000 ns (1 ms). Frame PTS inputs are
//     therefore quantised to 1 ms.

import 'dart:typed_data';

// EBML element IDs (kept in their on-disk "with marker bit" form).
const int _idEbml = 0x1A45DFA3;
const int _idEbmlVersion = 0x4286;
const int _idEbmlReadVersion = 0x42F7;
const int _idEbmlMaxIdLength = 0x42F2;
const int _idEbmlMaxSizeLength = 0x42F3;
const int _idDocType = 0x4282;
const int _idDocTypeVersion = 0x4287;
const int _idDocTypeReadVersion = 0x4285;

const int _idSegment = 0x18538067;
const int _idInfo = 0x1549A966;
const int _idTimestampScale = 0x2AD7B1;
const int _idMuxingApp = 0x4D80;
const int _idWritingApp = 0x5741;
const int _idDuration = 0x4489;

const int _idTracks = 0x1654AE6B;
const int _idTrackEntry = 0xAE;
const int _idTrackNumber = 0xD7;
const int _idTrackUid = 0x73C5;
const int _idFlagLacing = 0x9C;
const int _idLanguage = 0x22B59C;
const int _idCodecId = 0x86;
const int _idTrackType = 0x83;
const int _idDefaultDuration = 0x23E383;
const int _idVideo = 0xE0;
const int _idPixelWidth = 0xB0;
const int _idPixelHeight = 0xBA;

const int _idCluster = 0x1F43B675;
const int _idTimestamp = 0xE7;
const int _idSimpleBlock = 0xA3;

const int _idCues = 0x1C53BB6B;
const int _idCuePoint = 0xBB;
const int _idCueTime = 0xB3;
const int _idCueTrackPositions = 0xB7;
const int _idCueTrack = 0xF7;
const int _idCueClusterPosition = 0xF1;

const int _videoTrackNumber = 1;
const int _timestampScaleNanos = 1000000;

/// One pending video frame.
class _PendingFrame {
  _PendingFrame(this.timestampMs, this.isKeyFrame, this.data);
  final int timestampMs;
  final bool isKeyFrame;
  final Uint8List data;
}

/// One pending cluster of frames (up to but excluding the next keyframe).
class _PendingCluster {
  _PendingCluster(this.timestampMs);
  final int timestampMs;
  final List<_PendingFrame> frames = <_PendingFrame>[];
}

/// Builds a .webm byte stream that wraps a sequence of VP8 frames.
///
/// Usage:
/// ```dart
/// final w = WebmWriter(width: 640, height: 360);
/// while (...) {
///   w.addFrame(payload, ptsNanos: pts, isKeyFrame: kf);
/// }
/// final Uint8List bytes = w.finish();
/// File('out.webm').writeAsBytesSync(bytes);
/// ```
class WebmWriter {
  WebmWriter({
    required this.width,
    required this.height,
    this.frameRate,
  });

  /// Pixel dimensions of the video. Required.
  final int width;
  final int height;

  /// Optional frame rate in Hz. When provided, written as the video
  /// track's DefaultDuration so players can derive an exact frame rate.
  final double? frameRate;

  final List<_PendingCluster> _clusters = <_PendingCluster>[];

  /// Append one frame. [ptsNanos] is the presentation timestamp; will be
  /// quantised to 1 ms. [isKeyFrame] starts a new Cluster.
  void addFrame(
    Uint8List data, {
    required int ptsNanos,
    required bool isKeyFrame,
  }) {
    final int ms = ptsNanos ~/ _timestampScaleNanos;
    if (_clusters.isEmpty) {
      if (!isKeyFrame) {
        throw StateError(
            'WebmWriter: first frame must be a keyframe (got inter)');
      }
      _clusters.add(_PendingCluster(ms));
    } else if (isKeyFrame) {
      _clusters.add(_PendingCluster(ms));
    } else {
      // Sanity: delta must fit signed int16 (±32 s at 1 ms scale).
      final int delta = ms - _clusters.last.timestampMs;
      if (delta < -32768 || delta > 32767) {
        throw StateError(
            'WebmWriter: frame too far from cluster start ($delta ms); '
            'force a keyframe more often');
      }
    }
    _clusters.last.frames.add(_PendingFrame(ms, isKeyFrame, data));
  }

  /// Serialise the accumulated frames as a complete .webm byte stream.
  Uint8List finish() {
    if (_clusters.isEmpty) {
      throw StateError('WebmWriter: no frames added');
    }

    final bb = _ByteBuf();

    // 1. EBML header.
    final ebmlBody = _ByteBuf()
      ..writeUintEl(_idEbmlVersion, 1)
      ..writeUintEl(_idEbmlReadVersion, 1)
      ..writeUintEl(_idEbmlMaxIdLength, 4)
      ..writeUintEl(_idEbmlMaxSizeLength, 8)
      ..writeStringEl(_idDocType, 'webm')
      ..writeUintEl(_idDocTypeVersion, 2)
      ..writeUintEl(_idDocTypeReadVersion, 2);
    bb.writeMaster(_idEbml, ebmlBody.takeBytes());

    // 2. Build Segment payload (Info, Tracks, Clusters..., Cues).
    final segBody = _ByteBuf();

    // 2a. Info.
    final lastFrame = _clusters.last.frames.last;
    final int durationMs = lastFrame.timestampMs + 1;
    final infoBody = _ByteBuf()
      ..writeUintEl(_idTimestampScale, _timestampScaleNanos)
      ..writeStringEl(_idMuxingApp, 'dart_vp8')
      ..writeStringEl(_idWritingApp, 'dart_vp8.WebmWriter')
      ..writeFloatEl(_idDuration, durationMs.toDouble());
    segBody.writeMaster(_idInfo, infoBody.takeBytes());

    // 2b. Tracks.
    final videoBody = _ByteBuf()
      ..writeUintEl(_idPixelWidth, width)
      ..writeUintEl(_idPixelHeight, height);
    final entryBody = _ByteBuf()
      ..writeUintEl(_idTrackNumber, _videoTrackNumber)
      ..writeUintEl(_idTrackUid, _videoTrackNumber)
      ..writeUintEl(_idFlagLacing, 0)
      ..writeStringEl(_idLanguage, 'und')
      ..writeStringEl(_idCodecId, 'V_VP8')
      ..writeUintEl(_idTrackType, 1);
    if (frameRate != null && frameRate! > 0) {
      entryBody.writeUintEl(_idDefaultDuration, (1e9 / frameRate!).round());
    }
    entryBody.writeMaster(_idVideo, videoBody.takeBytes());
    final tracksBody = _ByteBuf()
      ..writeMaster(_idTrackEntry, entryBody.takeBytes());
    segBody.writeMaster(_idTracks, tracksBody.takeBytes());

    // 2c. Clusters. We need each cluster's offset within the Segment
    //     payload to populate Cues, so emit them and remember offsets.
    final List<int> clusterOffsets = <int>[];
    final List<int> clusterTimes = <int>[];
    for (final cluster in _clusters) {
      clusterOffsets.add(segBody.length);
      clusterTimes.add(cluster.timestampMs);

      final clusterBody = _ByteBuf()
        ..writeUintEl(_idTimestamp, cluster.timestampMs);
      for (final f in cluster.frames) {
        final delta = f.timestampMs - cluster.timestampMs;
        clusterBody.writeBytes(_buildSimpleBlock(
          trackNumber: _videoTrackNumber,
          delta: delta,
          isKeyFrame: f.isKeyFrame,
          payload: f.data,
        ));
      }
      segBody.writeMaster(_idCluster, clusterBody.takeBytes());
    }

    // 2d. Cues — one entry per cluster (one per keyframe).
    final cuesBody = _ByteBuf();
    for (int i = 0; i < clusterOffsets.length; i++) {
      final tpBody = _ByteBuf()
        ..writeUintEl(_idCueTrack, _videoTrackNumber)
        ..writeUintEl(_idCueClusterPosition, clusterOffsets[i]);
      final ptBody = _ByteBuf()
        ..writeUintEl(_idCueTime, clusterTimes[i])
        ..writeMaster(_idCueTrackPositions, tpBody.takeBytes());
      cuesBody.writeMaster(_idCuePoint, ptBody.takeBytes());
    }
    segBody.writeMaster(_idCues, cuesBody.takeBytes());

    bb.writeMaster(_idSegment, segBody.takeBytes());
    return bb.takeBytes();
  }
}

/// Build a SimpleBlock element (header + payload) as a standalone byte
/// blob. Layout:
///   ID 0xA3, size VINT, body = (track-VINT, int16 BE delta, flags, data).
Uint8List _buildSimpleBlock({
  required int trackNumber,
  required int delta,
  required bool isKeyFrame,
  required Uint8List payload,
}) {
  final track = _encodeVint(trackNumber);
  final body = Uint8List(track.length + 3 + payload.length);
  int o = 0;
  body.setRange(o, o + track.length, track);
  o += track.length;
  // Big-endian signed 16-bit delta.
  final int d = delta < 0 ? delta + 0x10000 : delta;
  body[o++] = (d >> 8) & 0xFF;
  body[o++] = d & 0xFF;
  // Flags: bit 0x80 keyframe; lacing bits 0; bit 0x01 invisible 0.
  body[o++] = isKeyFrame ? 0x80 : 0x00;
  body.setRange(o, o + payload.length, payload);

  final wrapper = _ByteBuf()..writeMaster(_idSimpleBlock, body);
  return wrapper.takeBytes();
}

// --- low-level EBML serialisation -----------------------------------------

/// Encode an unsigned integer as a VINT with the smallest possible
/// length. Used for sizes and for trackNumber inside SimpleBlock.
Uint8List _encodeVint(int v) {
  // The maximum value representable in an N-byte VINT is (1<<(7N))-1
  // (the all-ones value is reserved for "unknown size", but for IDs/
  // sizes < that, N bytes is enough).
  if (v < 0) {
    throw ArgumentError('VINT cannot encode negative: $v');
  }
  int n = 1;
  while (n <= 8 && v >= (1 << (7 * n)) - 1) {
    n++;
  }
  if (n > 8) {
    throw ArgumentError('VINT value too large: $v');
  }
  final out = Uint8List(n);
  // Top bit pattern: marker bit at position (8-n) within byte 0.
  final int marker = 1 << (8 - n);
  for (int i = n - 1; i >= 0; i--) {
    out[i] = v & 0xFF;
    v >>= 8;
  }
  out[0] |= marker;
  return out;
}

/// Encode an element ID. IDs already include their marker bit, so we
/// just emit them in big-endian using their natural byte length.
Uint8List _encodeId(int id) {
  int n;
  if (id <= 0xFF) {
    n = 1;
  } else if (id <= 0xFFFF) {
    n = 2;
  } else if (id <= 0xFFFFFF) {
    n = 3;
  } else {
    n = 4;
  }
  final out = Uint8List(n);
  for (int i = n - 1; i >= 0; i--) {
    out[i] = id & 0xFF;
    id >>= 8;
  }
  return out;
}

class _ByteBuf {
  final BytesBuilder _bb = BytesBuilder(copy: false);

  int get length => _bb.length;

  void writeBytes(Uint8List b) => _bb.add(b);

  Uint8List takeBytes() => _bb.toBytes();

  void writeMaster(int id, Uint8List body) {
    _bb.add(_encodeId(id));
    _bb.add(_encodeVint(body.length));
    _bb.add(body);
  }

  void writeUintEl(int id, int value) {
    // Smallest big-endian byte length that fits.
    int n = 1;
    int probe = value;
    while (probe > 0xFF) {
      probe >>= 8;
      n++;
    }
    if (n > 8) throw ArgumentError('uint too large: $value');
    final body = Uint8List(n);
    int v = value;
    for (int i = n - 1; i >= 0; i--) {
      body[i] = v & 0xFF;
      v >>= 8;
    }
    writeMaster(id, body);
  }

  void writeStringEl(int id, String s) {
    writeMaster(id, Uint8List.fromList(s.codeUnits));
  }

  void writeFloatEl(int id, double v) {
    final body = Uint8List(8);
    ByteData.sublistView(body).setFloat64(0, v);
    writeMaster(id, body);
  }
}
