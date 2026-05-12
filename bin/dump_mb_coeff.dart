import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-013' : args[0];
  final frame = args.length > 1 ? int.parse(args[1]) : 1;
  final mbR = args.length > 2 ? int.parse(args[2]) : 1;
  final mbC = args.length > 3 ? int.parse(args[3]) : 0;

  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  final mbCols = 11;
  final targetGlobal = frame * mbCols * 9 + mbR * mbCols + mbC;
  dec.debugPerMbHook = (idx, qcoeff, eobs, mb, dq) {
    if (idx == targetGlobal) {
      final eobList = [for (int i = 0; i < 25; i++) eobs[i]];
      print('MB($mbR,$mbC) f=$frame mode=${mb.yMode} ref=${mb.refFrame} '
          'skip=${mb.skipCoeff} is4x4=${mb.is4x4} eobs=$eobList '
          'dq_y1_dc=${dq.y1Dc} dq_y1_ac=${dq.y1Ac} '
          'dq_uv_dc=${dq.uvDc} dq_uv_ac=${dq.uvAc} '
          'dq_y2_dc=${dq.y2Dc} dq_y2_ac=${dq.y2Ac}');
      for (int b = 0; b < 25; b++) {
        bool any = false;
        final parts = <String>[];
        for (int k = 0; k < 16; k++) {
          final v = qcoeff[b * 16 + k];
          if (v != 0) {
            any = true;
            parts.add('[$k]=$v');
          }
        }
        if (any) print('  block $b: ${parts.join(' ')}');
      }
    }
  };
  for (int f = 0; f <= frame; f++) {
    final ivfFrame = reader.nextFrame();
    if (ivfFrame == null) break;
    dec.decode(ivfFrame);
  }
}
