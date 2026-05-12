import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final target = int.parse(args.isNotEmpty ? args[0] : '218');

  final ivf = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();

  dec.debugPerMbHook = (g, q, eobs, mb, dq) {
    if (g != target) return;
    final view = Int16List.fromList(q);
    final eobsCopy = Uint8List.fromList(eobs);

    if (!mb.skipCoeff && mb.yMode != bPred && mb.yMode != splitMv) {
      view[24 * 16] = (view[24 * 16] * dq.y2Dc).toSigned(32);
      for (int i = 1; i < 16; i++) {
        view[24 * 16 + i] = (view[24 * 16 + i] * dq.y2Ac).toSigned(32);
      }
      if (eobsCopy[24] > 1) {
        inverseWalsh4x4(view, 24 * 16, view, 0);
      } else {
        inverseWalsh4x4Dc(view[24 * 16], view, 0);
      }
    }

    stdout.write('QC mb=$g eobs=[');
    for (int i = 0; i < 25; i++) {
      stdout.write('${eobsCopy[i]},');
    }
    stdout.writeln(
        '] y1Dc=${dq.y1Dc} y1Ac=${dq.y1Ac} y2Dc=${dq.y2Dc} y2Ac=${dq.y2Ac} uvDc=${dq.uvDc} uvAc=${dq.uvAc}');
    stdout.writeln(
        '  mode=${mb.yMode} ref=${mb.refFrame} skip=${mb.skipCoeff} mv=(${mb.mv.row},${mb.mv.col})');
    for (int i = 0; i < 16; i++) {
      stdout.write('  Y${i.toString().padLeft(2)}:');
      for (int k = 0; k < 16; k++) {
        stdout.write(' ${view[i * 16 + k]}');
      }
      stdout.writeln();
    }
    for (int i = 16; i < 24; i++) {
      stdout.write('  C${i.toString().padLeft(2)}:');
      for (int k = 0; k < 16; k++) {
        stdout.write(' ${view[i * 16 + k]}');
      }
      stdout.writeln();
    }
  };

  for (int i = 0; i < 3; i++) {
    dec.decode(reader.nextFrame()!);
  }
}
