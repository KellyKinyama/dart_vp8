import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

Uint8List cropPlane(Uint8List src, int stride, int w, int h) {
  if (stride == w) return Uint8List.sublistView(src, 0, w * h);
  final out = Uint8List(w * h);
  for (int r = 0; r < h; r++) {
    out.setRange(r * w, r * w + w, src, r * stride);
  }
  return out;
}

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-013' : args[0];
  final frameIdx = args.length >= 2 ? int.parse(args[1]) : 1;
  final mbR = args.length >= 3 ? int.parse(args[2]) : 1;
  final mbC = args.length >= 4 ? int.parse(args[3]) : 0;
  final refPath = args.length >= 5 ? args[4] : null;

  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  late DecodedFrame d;
  for (int i = 0; i <= frameIdx; i++) {
    d = dec.decode(reader.nextFrame()!);
  }
  final mis = dec.debugLastModeInfo;
  final mi = mis[mbR * dec.debugMbCols + mbC];
  print('MB($mbR,$mbC) mode=${mi.yMode} ref=${mi.refFrame} '
      'skip=${mi.skipCoeff} is4x4=${mi.is4x4} seg=${mi.segmentId} '
      'mv=(${mi.mv.row},${mi.mv.col}) uvMode=${mi.uvMode}');
  print('Dart Y of MB($mbR,$mbC):');
  for (int r = 0; r < 16; r++) {
    final row = <int>[];
    for (int c = 0; c < 16; c++) {
      row.add(d.y[(mbR * 16 + r) * d.yStride + mbC * 16 + c]);
    }
    print('  r$r ${row.toString()}');
  }
  if (refPath != null) {
    final ref = File(refPath).readAsBytesSync();
    final yLen = d.width * d.height;
    final uvLen = ((d.width + 1) >> 1) * ((d.height + 1) >> 1);
    final fOff = frameIdx * (yLen + 2 * uvLen);
    print('Ref Y of MB($mbR,$mbC):');
    for (int r = 0; r < 16; r++) {
      final row = <int>[];
      for (int c = 0; c < 16; c++) {
        row.add(ref[fOff + (mbR * 16 + r) * d.width + mbC * 16 + c]);
      }
      print('  r$r ${row.toString()}');
    }
  }
}
