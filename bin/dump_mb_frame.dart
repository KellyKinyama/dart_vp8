import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final name = args[0];
  final frame = int.parse(args[1]);
  final mbR = int.parse(args[2]);
  final mbC = int.parse(args[3]);
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final ref =
      File('C:/Temp/${name.substring(name.length - 3)}.yuv').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  for (int i = 0; i <= frame; i++) {
    final f = reader.nextFrame()!;
    final d = dec.decode(f);
    if (i != frame) continue;
    final w = d.width, h = d.height;
    final off = frame * w * h * 3 ~/ 2;
    print('MB($mbR,$mbC) frame $frame:');
    for (int rr = 0; rr < 16; rr++) {
      final dy = <int>[];
      final ry = <int>[];
      for (int cc = 0; cc < 16; cc++) {
        dy.add(d.y[(mbR * 16 + rr) * d.yStride + mbC * 16 + cc]);
        ry.add(ref[off + (mbR * 16 + rr) * w + mbC * 16 + cc]);
      }
      final diff = [for (int k = 0; k < 16; k++) dy[k] - ry[k]];
      print('r$rr d=$dy');
      print('    r=$ry');
      print('    Δ=$diff');
    }
  }
}
