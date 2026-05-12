// Detailed per-frame diff against a libvpx-produced YUV reference.
//
// Reads test/fixtures/vp80-00-comprehensive-001.yuv (produced by
// `vpxdec --i420`) and compares each I420 frame to our decode output.
// Reports the first byte that differs and shows a window around it.

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

const int frameBytes = 176 * 144 * 3 ~/ 2; // 38016

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final ref = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.yuv')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();

  int idx = 0;
  while (true) {
    final f = reader.nextFrame();
    if (f == null) break;
    final df = dec.decode(f);
    final w = df.width;
    final h = df.height;

    // Build I420 from decoded planes (cropped).
    final got = Uint8List(frameBytes);
    int off = 0;
    for (int r = 0; r < h; r++) {
      got.setRange(off, off + w, df.y, r * df.yStride);
      off += w;
    }
    final cw = w >> 1;
    final ch = h >> 1;
    for (int r = 0; r < ch; r++) {
      got.setRange(off, off + cw, df.u, r * df.uvStride);
      off += cw;
    }
    for (int r = 0; r < ch; r++) {
      got.setRange(off, off + cw, df.v, r * df.uvStride);
      off += cw;
    }

    final refStart = idx * frameBytes;
    int firstDiff = -1;
    for (int i = 0; i < frameBytes; i++) {
      if (got[i] != ref[refStart + i]) {
        firstDiff = i;
        break;
      }
    }
    if (firstDiff < 0) {
      print('frame $idx OK');
    } else {
      // Where is firstDiff?
      final int yEnd = w * h;
      final int uEnd = yEnd + cw * ch;
      String plane;
      int planeOff;
      int planeRow;
      int planeCol;
      int planeW;
      if (firstDiff < yEnd) {
        plane = 'Y';
        planeOff = firstDiff;
        planeW = w;
      } else if (firstDiff < uEnd) {
        plane = 'U';
        planeOff = firstDiff - yEnd;
        planeW = cw;
      } else {
        plane = 'V';
        planeOff = firstDiff - uEnd;
        planeW = cw;
      }
      planeRow = planeOff ~/ planeW;
      planeCol = planeOff % planeW;
      print(
          'frame $idx DIFF at byte=$firstDiff plane=$plane row=$planeRow col=$planeCol');
      print(
          '  want=${ref.sublist(refStart + firstDiff, refStart + firstDiff + 16).toList()}');
      print('  got =${got.sublist(firstDiff, firstDiff + 16).toList()}');
      // Show 8 bytes before
      final back = firstDiff >= 8 ? firstDiff - 8 : 0;
      print(
          '  context want=${ref.sublist(refStart + back, refStart + back + 24).toList()}');
      print('  context got =${got.sublist(back, back + 24).toList()}');
      // MB coord
      print(
          '  MB row=${planeRow ~/ (plane == 'Y' ? 16 : 8)} col=${planeCol ~/ (plane == 'Y' ? 16 : 8)}');
      break;
    }
    idx++;
  }
}
