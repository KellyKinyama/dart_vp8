// Container-agnostic VP8 reader. Auto-detects IVF vs WebM from the
// first few bytes of the input and yields VP8 payloads.

import 'dart:typed_data';

import 'ivf_reader.dart';
import 'webm_reader.dart';

/// One demuxed VP8 frame. Container-agnostic.
class Vp8Packet {
  Vp8Packet({
    required this.data,
    required this.ptsNanos,
    this.containerKeyFrame,
  });

  /// Compressed VP8 payload (zero-copy view into the source buffer).
  final Uint8List data;

  /// Presentation timestamp in nanoseconds, or 0 if the container has
  /// no timing info. For IVF the value is the raw PTS field unscaled
  /// (IVF stores time in container-defined units, not nanoseconds);
  /// callers needing accurate IVF timing should read the file header
  /// directly via [IvfReader].
  final int ptsNanos;

  /// Container-side keyframe flag if known (WebM SimpleBlock keyframe
  /// bit). Always null for IVF / Block-in-BlockGroup. The VP8 frame
  /// tag itself is the source of truth — `Vp8Decoder` re-derives
  /// keyframe-ness from the bitstream.
  final bool? containerKeyFrame;
}

/// Auto-detecting VP8 demuxer over an in-memory byte buffer. Picks
/// [IvfReader] or [WebmReader] based on the first 4 bytes.
class Vp8Reader {
  Vp8Reader._(this._next);

  /// Pixel width of the video, or 0 if unknown.
  late final int width;

  /// Pixel height of the video, or 0 if unknown.
  late final int height;

  final Vp8Packet? Function() _next;

  /// Sniff the container and construct a reader.
  factory Vp8Reader(Uint8List bytes) {
    if (bytes.length < 4) {
      throw const FormatException('Vp8Reader: buffer too small to sniff');
    }
    // IVF: 'DKIF'.
    if (bytes[0] == 0x44 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x49 &&
        bytes[3] == 0x46) {
      final ivf = IvfReader(bytes);
      if (!ivf.header.isVp8) {
        throw FormatException(
            'Vp8Reader: IVF fourcc ${ivf.header.fourcc.toRadixString(16)} '
            'is not VP8');
      }
      final r = Vp8Reader._(() {
        final f = ivf.nextFrame();
        if (f == null) return null;
        return Vp8Packet(data: f.data, ptsNanos: f.pts);
      });
      r.width = ivf.header.width;
      r.height = ivf.header.height;
      return r;
    }
    // EBML/WebM: 0x1A 0x45 0xDF 0xA3.
    if (bytes[0] == 0x1A &&
        bytes[1] == 0x45 &&
        bytes[2] == 0xDF &&
        bytes[3] == 0xA3) {
      final wm = WebmReader(bytes);
      final r = Vp8Reader._(() {
        final f = wm.nextFrame();
        if (f == null) return null;
        return Vp8Packet(
          data: f.data,
          ptsNanos: f.ptsNanos,
          containerKeyFrame: f.isKeyFrame,
        );
      });
      r.width = wm.width;
      r.height = wm.height;
      return r;
    }
    throw const FormatException(
        'Vp8Reader: unrecognised container (need IVF or WebM)');
  }

  /// Returns the next compressed VP8 packet, or null at end-of-stream.
  Vp8Packet? nextPacket() => _next();
}
