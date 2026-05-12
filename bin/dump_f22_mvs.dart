import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  dec.debugSkipLoopFilter = true;
  for (int i = 0; i <= 22; i++) {
    final df = dec.decode(reader.nextFrame()!);
    if (i == 22) {
      final mis = dec.debugLastModeInfo;
      final mbCols = dec.debugMbCols;
      final base = 22 * 99;
      final out = StringBuffer();
      for (int idx = 0; idx < mis.length; idx++) {
        final m = mis[idx];
        out.writeln('FMV mb=${base + idx} mode=${m.yMode} ref=${m.refFrame} '
            'mv=(${m.mv.row},${m.mv.col}) skip=${m.skipCoeff ? 1 : 0}');
      }
      File('c:/Temp/dart_f22_mvs.txt').writeAsStringSync(out.toString());
    }
  }
}
