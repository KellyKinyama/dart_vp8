// Compare dart MB(0,2) row 15 with and without LF for vp80-00-comprehensive-003 frame 1.
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

Future<List<int>> getRow15(bool skipLf) async {
  final ivf =
      File('test/fixtures/vp80-00-comprehensive-003.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  dec.debugSkipLoopFilter = skipLf;
  DecodedFrame? d;
  for (int i = 0; i <= 1; i++) {
    final f = reader.nextFrame();
    if (f == null) break;
    d = dec.decode(f);
  }
  // MB(0,2) cols 32..47, plus MB(1,2) row 0 (=row 16 of frame).
  final y = d!.y;
  final w = d.width;
  final out = <int>[];
  // MB(0,2) row 14 cols 32..47
  for (int c = 32; c < 48; c++) out.add(y[14 * w + c]);
  // MB(0,2) row 15
  for (int c = 32; c < 48; c++) out.add(y[15 * w + c]);
  // MB(1,2) row 0 (frame row 16)
  for (int c = 32; c < 48; c++) out.add(y[16 * w + c]);
  // MB(1,2) row 1 (frame row 17)
  for (int c = 32; c < 48; c++) out.add(y[17 * w + c]);
  return out;
}

void main() async {
  final withLf = await getRow15(false);
  final noLf = await getRow15(true);
  final ref = File('C:/Temp/003_nolf.yuv').readAsBytesSync();
  final refLf = File('C:/Temp/003.yuv').readAsBytesSync();
  final frameSize = 176 * 144 * 3 ~/ 2;
  final off = frameSize * 1;
  final refOut = <int>[];
  final refLfOut = <int>[];
  for (final r in [14, 15, 16, 17]) {
    for (int c = 32; c < 48; c++) {
      refOut.add(ref[off + r * 176 + c]);
      refLfOut.add(refLf[off + r * 176 + c]);
    }
  }
  for (int i = 0; i < 4; i++) {
    final r = [14, 15, 16, 17][i];
    final s = i * 16;
    final e = s + 16;
    print('row $r:');
    print('  dart noLF : ${noLf.sublist(s, e)}');
    print('  ref  noLF : ${refOut.sublist(s, e)}');
    print('  dart LF   : ${withLf.sublist(s, e)}');
    print('  ref  LF   : ${refLfOut.sublist(s, e)}');
  }
}
