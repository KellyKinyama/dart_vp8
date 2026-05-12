import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

// Snapshot the reference-frame source row that frame 2 MB(1,9) reads from,
// then run our sixtap horizontal filter manually and compare against the
// libvpx-expected predictor.
void main() {
  final ivf = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();

  Uint8List? snap;
  int? snapStride;
  int? snapOff;

  dec.debugPerMbHook = (g, q, eobs, mb, dq) {
    if (g != 218) return;
    // MB(1,9) frame 2: MV in 1/8 pel.
    final mv = mb.mv;
    final mbRow = 1, mbCol = 9;
    // Snapshot ref-frame, refLast.
    // We need to peek into the decoder's _refLast directly; can't. Re-derive
    // via the source row from the ALREADY-decoded planes? No: refLast was
    // updated after frame 1 decode, so at hook time during frame 2, refLast
    // holds frame 1's reconstruction.
    // Approach: print MV and continue; we'll instrument differently.
    stdout.writeln(
        'MB 218 mv=(${mv.row},${mv.col}) ref=${mb.refFrame} mode=${mb.yMode}');
    stdout.writeln('  intCol=${mv.col >> 3} subCol=${mv.col & 7}');
    stdout.writeln('  intRow=${mv.row >> 3} subRow=${mv.row & 7}');
    stdout.writeln('  src x base = ${mbCol * 16 + (mv.col >> 3)}');
    stdout.writeln('  src y base = ${mbRow * 16 + (mv.row >> 3)}');
  };

  for (int i = 0; i < 3; i++) {
    dec.decode(reader.nextFrame()!);
  }
}
