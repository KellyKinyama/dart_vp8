import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivf = File('test/fixtures/vp80-00-comprehensive-003.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  for (int i = 0; i < 2; i++) {
    final f = reader.nextFrame();
    if (f == null) break;
    dec.decode(f);
  }
}
