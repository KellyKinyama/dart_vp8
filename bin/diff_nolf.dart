import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final ref = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.nolf.yuv')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  dec.debugSkipLoopFilter = true;
  for (int i = 0; i < 29; i++) {
    final f = reader.nextFrame()!;
    final df = dec.decode(f);
    final fOff = i * 38016;
    int firstDiff = -1;
    for (int b = 0; b < 176 * 144 && firstDiff < 0; b++) {
      final r = b ~/ 176;
      final c = b % 176;
      if (df.y[r * df.yStride + c] != ref[fOff + b]) firstDiff = b;
    }
    if (firstDiff >= 0) {
      final r = firstDiff ~/ 176;
      final c = firstDiff % 176;
      print(
          'frame $i NO-LF first Y diff at byte $firstDiff (r=$r c=$c MB(${r ~/ 16},${c ~/ 16}))');
    } else {
      print('frame $i NO-LF Y matches');
    }
  }
}
