import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-018' : args[0];
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  dec.decode(reader.nextFrame()!);
  final mis = dec.debugLastModeInfo;
  final cols = dec.debugMbCols;
  for (int c = 0; c < cols; c++) {
    final mi = mis[1 * cols + c];
    if (!mi.is4x4) continue;
    final parts = [for (int i = 0; i < 16; i++) mi.bModes[i].toString()];
    print('MB(1,$c) bmodes: ${parts.join(' ')}');
  }
}
