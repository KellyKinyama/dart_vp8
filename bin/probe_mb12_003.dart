import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivf =
      File('test/fixtures/vp80-00-comprehensive-003.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  dec.debugPerMbHook = (g, q, eobs, mb, dq) {
    if (g < 99 || g >= 99 + 99) return;
    final r = (g - 99) ~/ 11;
    final c = (g - 99) % 11;
    if (r < 3 || r > 5) return;
    print(
        'f1 MB($r,$c) mode=${mb.yMode} ref=${mb.refFrame} mv=(${mb.mv.row},${mb.mv.col}) seg=${mb.segmentId} skip=${mb.skipCoeff} is4x4=${mb.is4x4}');
  };
  for (int i = 0; i <= 1; i++) {
    dec.decode(reader.nextFrame()!);
  }
}
