// VP8 conformance test against the upstream libvpx test vector
// `vp80-00-comprehensive-001.ivf` (a 176x144 stream). The companion
// `.ivf.md5` file lists one MD5 per decoded frame, computed over the
// raw I420 bytes (Y plane then U then V, cropped to width*height).
//
// We decode every frame with [Vp8Decoder], crop the output planes to the
// frame dimensions, and assert each frame's MD5 matches the expected
// value. This is the first end-to-end test against a non-synthetic
// bitstream.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

/// Crop a plane that has stride `stride` and `height` rows down to
/// `width * height` packed bytes.
Uint8List cropPlane(Uint8List src, int stride, int width, int height) {
  if (stride == width) {
    return Uint8List.sublistView(src, 0, width * height);
  }
  final out = Uint8List(width * height);
  for (int r = 0; r < height; r++) {
    out.setRange(
      r * width,
      r * width + width,
      src,
      r * stride,
    );
  }
  return out;
}

/// Parse the .ivf.md5 sidecar into a list of expected MD5 hex strings,
/// one per frame, in stream order.
List<String> parseMd5File(String path) {
  final lines = File(path).readAsLinesSync();
  final out = <String>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final sp = t.indexOf(RegExp(r'\s'));
    if (sp <= 0) continue;
    out.add(t.substring(0, sp).toLowerCase());
  }
  return out;
}

void main() {
  group('VP8 conformance: vp80-00-comprehensive-001', () {
    final ivfPath = 'test/fixtures/vp80-00-comprehensive-001.ivf';
    final md5Path = '$ivfPath.md5';

    test('all frames decode and match libvpx MD5s', () {
      if (!File(ivfPath).existsSync()) {
        markTestSkipped('missing fixture: $ivfPath');
        return;
      }

      final ivfBytes = File(ivfPath).readAsBytesSync();
      final reader = IvfReader(Uint8List.fromList(ivfBytes));
      final expected = parseMd5File(md5Path);

      final dec = Vp8Decoder();
      int frameIdx = 0;
      while (true) {
        final f = reader.nextFrame();
        if (f == null) break;
        final dframe = dec.decode(f);
        if (!dframe.isShown) continue;

        final yCrop =
            cropPlane(dframe.y, dframe.yStride, dframe.width, dframe.height);
        final uvW = (dframe.width + 1) >> 1;
        final uvH = (dframe.height + 1) >> 1;
        final uCrop = cropPlane(dframe.u, dframe.uvStride, uvW, uvH);
        final vCrop = cropPlane(dframe.v, dframe.uvStride, uvW, uvH);

        final concat = Uint8List(yCrop.length + uCrop.length + vCrop.length);
        concat.setRange(0, yCrop.length, yCrop);
        concat.setRange(yCrop.length, yCrop.length + uCrop.length, uCrop);
        concat.setRange(yCrop.length + uCrop.length, concat.length, vCrop);

        final got = md5.convert(concat).toString();
        final want = expected[frameIdx];
        expect(got, want,
            reason:
                'Frame $frameIdx (${dframe.width}x${dframe.height}, kf=${dframe.isKeyFrame}) MD5 mismatch');
        frameIdx++;
      }
      expect(frameIdx, expected.length,
          reason: 'decoded $frameIdx frames, expected ${expected.length}');
    });
  });
}
