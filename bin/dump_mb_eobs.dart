import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-012' : args[0];
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  final targetMb = 7 * 11 + 5; // row 7 col 5, 11 mb cols for 176-wide
  dec.debugPerMbHook = (idx, qcoeff, eobs, mb, dq) {
    if (idx == targetMb) {
      stderr.write('MB(7,5) eobs:');
      for (int i = 0; i < 25; i++) {
        stderr.write(' [$i]=${eobs[i]}');
      }
      stderr.writeln();
      // Print non-zero qcoeff
      for (int b = 0; b < 25; b++) {
        for (int k = 0; k < 16; k++) {
          final v = qcoeff[b * 16 + k];
          if (v != 0) stderr.writeln('  block=$b zigzag=$k val=$v');
        }
      }
    }
  };
  dec.decode(reader.nextFrame()!);
}
