// Temporary diagnostic: dump per-frame header flags + a few sample
// decoded pixels for the conformance fixture, and find where the
// reconstruction first diverges from libvpx.

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final bytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(bytes));
  final dec = Vp8Decoder();
  final expectedMd5s = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf.md5')
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .map((l) => l.trim().split(RegExp(r'\s+'))[0].toLowerCase())
      .toList();

  int idx = 0;
  while (true) {
    final f = reader.nextFrame();
    if (f == null) break;
    // Parse the header for diagnostic info, then decode.
    final hdrByte0 = f.data[0];
    final isKey = (hdrByte0 & 1) == 0;
    final df = dec.decode(f);
    // Crop to width*height for MD5 computation.
    Uint8List cropPlane(Uint8List src, int stride, int w, int h) {
      if (stride == w) return Uint8List.sublistView(src, 0, w * h);
      final out = Uint8List(w * h);
      for (int r = 0; r < h; r++) {
        out.setRange(r * w, r * w + w, src, r * stride);
      }
      return out;
    }

    final yC = cropPlane(df.y, df.yStride, df.width, df.height);
    final uC = cropPlane(df.u, df.uvStride, df.width >> 1, df.height >> 1);
    final vC = cropPlane(df.v, df.uvStride, df.width >> 1, df.height >> 1);
    final concat = Uint8List(yC.length + uC.length + vC.length);
    concat.setRange(0, yC.length, yC);
    concat.setRange(yC.length, yC.length + uC.length, uC);
    concat.setRange(yC.length + uC.length, concat.length, vC);
    final got = md5.convert(concat).toString();
    final ok = got == expectedMd5s[idx];
    print(
        'frame=$idx kf=$isKey size=${f.data.length} md5_got=$got md5_want=${expectedMd5s[idx]} ${ok ? 'OK' : 'FAIL'}');
    if (!ok && idx <= 4) {
      // Per-plane MD5 to narrow which plane diverges.
      print('  yMD5=${md5.convert(yC)}');
      print('  uMD5=${md5.convert(uC)}');
      print('  vMD5=${md5.convert(vC)}');
      // Sample a mid-frame row.
      final w = df.width;
      final ys = df.yStride;
      final midRow = df.height ~/ 2;
      print(
          '  y[mid row 0..15]=${df.y.sublist(midRow * ys, midRow * ys + 16)}');
      print(
          '  y[mid row 80..95]=${df.y.sublist(midRow * ys + 80, midRow * ys + 96)}');
      // Histogram-ish: count distinct Y values.
      final seen = <int>{};
      for (var v in df.y) {
        seen.add(v);
      }
      print('  distinct Y values=${seen.length}');
      // First non-16 Y pixel offset.
      for (int i = 0; i < df.y.length; i++) {
        if (df.y[i] != 16) {
          print(
              '  first nonblack y at $i (row=${i ~/ ys} col=${i % ys}) val=${df.y[i]}');
          break;
        }
      }
      // Hash just the keyframe content — does frame 2 equal frame 1?
      print('  frame2.y == frame1? need re-decode to know');
    }
    if (!ok) break;
    idx++;
    if (idx >= 5) break;
  }
}
