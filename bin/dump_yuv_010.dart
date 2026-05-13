import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final ivf =
      File('test/fixtures/vp80-00-comprehensive-010.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  final out = File('c:/Temp/dt010.yuv').openSync(mode: FileMode.write);
  int idx = 0;
  while (true) {
    final f = reader.nextFrame();
    if (f == null) break;
    final df = dec.decode(f);
    if (df == null) continue;
    // Crop to display, write Y then U then V planes (already cropped in DecodedFrame).
    out.writeFromSync(df.y);
    out.writeFromSync(df.u);
    out.writeFromSync(df.v);
    idx++;
  }
  out.closeSync();
  print('wrote $idx frames');
}
