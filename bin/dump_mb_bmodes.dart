import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-011' : args[0];
  final frame = args.length > 1 ? int.parse(args[1]) : 1;
  final mbR = args.length > 2 ? int.parse(args[2]) : 6;
  final mbC = args.length > 3 ? int.parse(args[3]) : 8;
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  for (int f = 0; f <= frame; f++) {
    final fr = reader.nextFrame();
    if (fr == null) break;
    dec.decode(fr);
  }
  final mis = dec.debugLastModeInfo;
  final cols = dec.debugMbCols;
  final mi = mis[mbR * cols + mbC];
  print('MB($mbR,$mbC) is4x4=${mi.is4x4} mode=${mi.yMode} ref=${mi.refFrame}');
  if (mi.is4x4) {
    final parts = [for (int i = 0; i < 16; i++) mi.bModes[i].toString()];
    print(' bmodes: ${parts.join(' ')}');
  }
  // Also print neighbors
  for (final off in <List<int>>[
    [-1, 0],
    [0, -1],
    [-1, -1],
    [-1, 1]
  ]) {
    final r = mbR + off[0], c = mbC + off[1];
    if (r < 0 || c < 0 || r >= mis.length ~/ cols || c >= cols) continue;
    final n = mis[r * cols + c];
    print(
        '  neighbor MB($r,$c) is4x4=${n.is4x4} mode=${n.yMode} ref=${n.refFrame}'
        '${n.is4x4 ? " bmodes=${[
            for (int i = 0; i < 16; i++) n.bModes[i]
          ].join(' ')}" : ''}');
  }
}
