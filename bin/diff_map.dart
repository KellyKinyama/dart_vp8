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
  final refPath = args[2];

  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final dec = Vp8Decoder();
  late DecodedFrame d;
  for (int i = 0; i <= frameIdx; i++) {
    d = dec.decode(reader.nextFrame()!);
  }
  final ref = File(refPath).readAsBytesSync();
  final yLen = d.width * d.height;
  final uvLen = ((d.width + 1) >> 1) * ((d.height + 1) >> 1);
  final fOff = frameIdx * (yLen + 2 * uvLen);

  final mbRows = (d.height + 15) >> 4;
  final mbCols = (d.width + 15) >> 4;
  print('Y plane diff map per MB (count of differing pixels):');
  print('   ' + List.generate(mbCols, (c) => c.toString().padLeft(3)).join(''));
  for (int mbR = 0; mbR < mbRows; mbR++) {
    final row = StringBuffer('${mbR.toString().padLeft(2)} ');
    for (int mbC = 0; mbC < mbCols; mbC++) {
      int cnt = 0;
      final r0 = mbR * 16;
      final c0 = mbC * 16;
      for (int r = 0; r < 16 && r0 + r < d.height; r++) {
        for (int c = 0; c < 16 && c0 + c < d.width; c++) {
          final dv = d.y[(r0 + r) * d.yStride + c0 + c];
          final rv = ref[fOff + (r0 + r) * d.width + c0 + c];
          if (dv != rv) cnt++;
        }
      }
      row.write(cnt.toString().padLeft(3));
    }
    print(row.toString());
  }
  final mis = dec.debugLastModeInfo;
  print('Bad MBs:');
  for (int mbR = 0; mbR < mbRows; mbR++) {
    for (int mbC = 0; mbC < mbCols; mbC++) {
      int cnt = 0;
      final r0 = mbR * 16;
      final c0 = mbC * 16;
      for (int r = 0; r < 16 && r0 + r < d.height; r++) {
        for (int c = 0; c < 16 && c0 + c < d.width; c++) {
          if (d.y[(r0 + r) * d.yStride + c0 + c] !=
              ref[fOff + (r0 + r) * d.width + c0 + c]) cnt++;
        }
      }
      if (cnt > 0) {
        final mi = mis[mbR * mbCols + mbC];
        print('  MB($mbR,$mbC) cnt=$cnt mode=${mi.yMode} ref=${mi.refFrame} '
            'skip=${mi.skipCoeff} is4x4=${mi.is4x4} '
            'mv=(${mi.mv.row},${mi.mv.col})');
      }
    }
  }
}
