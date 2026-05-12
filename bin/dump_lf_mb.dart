import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-012' : args[0];
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  dec.decode(reader.nextFrame()!);
  final mis = dec.debugLastModeInfo;
  final mbCols = dec.debugMbCols;
  for (final rc in [
    [7, 4],
    [7, 5],
    [7, 6]
  ]) {
    final r = rc[0], c = rc[1];
    final mi = mis[r * mbCols + c];
    final fl = dec.debugFilterLevel(r * mbCols + c);
    print('MB($r,$c) fl=$fl mode=${mi.yMode} ref=${mi.refFrame} '
        'is4x4=${mi.is4x4} skip=${mi.skipCoeff} eobMax=${mi.eobMax} '
        'seg=${mi.segmentId}');
  }
}
