// Parameterized VP8 conformance test against the upstream libvpx
// `vp80-00-comprehensive-NNN.ivf` test vectors. Each `.ivf.md5` sidecar
// lists one MD5 per decoded frame, computed over the raw I420 bytes
// (Y plane then U then V, cropped to width*height).
//
// We decode every frame with [Vp8Decoder], crop the output planes to the
// frame dimensions, and assert each frame's MD5 matches the expected
// value. Missing fixtures are skipped, not failed, so this file can run
// even before all vectors are downloaded.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

Uint8List cropPlane(Uint8List src, int stride, int width, int height) {
  if (stride == width) {
    return Uint8List.sublistView(src, 0, width * height);
  }
  final out = Uint8List(width * height);
  for (int r = 0; r < height; r++) {
    out.setRange(r * width, r * width + width, src, r * stride);
  }
  return out;
}

List<String> parseMd5File(String path) {
  final out = <String>[];
  for (final line in File(path).readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty) continue;
    final sp = t.indexOf(RegExp(r'\s'));
    if (sp <= 0) continue;
    out.add(t.substring(0, sp).toLowerCase());
  }
  return out;
}

void runOne(String name) {
  final ivfPath = 'test/fixtures/$name.ivf';
  final md5Path = '$ivfPath.md5';

  test(name, () {
    if (!File(ivfPath).existsSync() || !File(md5Path).existsSync()) {
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
              'Frame $frameIdx (${dframe.width}x${dframe.height}, kf=${dframe.isKeyFrame}) MD5 mismatch in $name');
      frameIdx++;
    }
    expect(frameIdx, expected.length,
        reason:
            '$name: decoded $frameIdx frames, expected ${expected.length}');
  });
}

void main() {
  group('VP8 conformance: vp80-00-comprehensive suite', () {
    for (int i = 1; i <= 18; i++) {
      final id = i.toString().padLeft(3, '0');
      runOne('vp80-00-comprehensive-$id');
    }
  });
}
