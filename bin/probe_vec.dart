import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
  final name = args.isEmpty ? 'vp80-00-comprehensive-006' : args[0];
  final maxFrames = args.length >= 2 ? int.parse(args[1]) : 4;
  final refPath = args.length >= 3 ? args[2] : null;
  final ivfPath = 'test/fixtures/$name.ivf';
  final md5Path = '$ivfPath.md5';
  final ref = refPath != null
      ? File(refPath).readAsBytesSync()
      : Uint8List(0);
  int refOff = 0;

  final ivf = File(ivfPath).readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  final expectedLines = File(md5Path).readAsLinesSync();
  final expected = <String>[];
  for (final l in expectedLines) {
    final t = l.trim();
    if (t.isEmpty) continue;
    final sp = t.indexOf(RegExp(r'\s'));
    if (sp <= 0) continue;
    expected.add(t.substring(0, sp).toLowerCase());
  }

  final dec = Vp8Decoder();
  if (Platform.environment['NO_LF'] == '1') {
    dec.debugSkipLoopFilter = true;
  }
  for (int i = 0; i < maxFrames; i++) {
    final f = reader.nextFrame();
    if (f == null) break;
    final d = dec.decode(f);
    final y = cropPlane(d.y, d.yStride, d.width, d.height);
    final uvW = (d.width + 1) >> 1;
    final uvH = (d.height + 1) >> 1;
    final u = cropPlane(d.u, d.uvStride, uvW, uvH);
    final v = cropPlane(d.v, d.uvStride, uvW, uvH);
    final cat = Uint8List(y.length + u.length + v.length);
    cat.setRange(0, y.length, y);
    cat.setRange(y.length, y.length + u.length, u);
    cat.setRange(y.length + u.length, cat.length, v);
    final got = md5.convert(cat).toString();
    final ok = got == expected[i] ? 'OK ' : 'BAD';
    final yh = md5.convert(y).toString();
    final uh = md5.convert(u).toString();
    final vh = md5.convert(v).toString();
    print('  frame $i $ok dims=${d.width}x${d.height} '
        'kf=${d.isKeyFrame} y=$yh u=$uh v=$vh');
    print('      total got=$got want=${expected[i]}');
    if (refPath != null) {
      final yLen = d.width * d.height;
      final uvLen = uvW * uvH;
      int firstYDiff = -1, firstUDiff = -1, firstVDiff = -1;
      for (int k = 0; k < yLen; k++) {
        if (y[k] != ref[refOff + k]) { firstYDiff = k; break; }
      }
      for (int k = 0; k < uvLen; k++) {
        if (u[k] != ref[refOff + yLen + k]) { firstUDiff = k; break; }
      }
      for (int k = 0; k < uvLen; k++) {
        if (v[k] != ref[refOff + yLen + uvLen + k]) { firstVDiff = k; break; }
      }
      if (firstYDiff >= 0) {
        final r = firstYDiff ~/ d.width, c = firstYDiff % d.width;
        print('      Y first diff @byte $firstYDiff (r=$r c=$c) '
            'dart=${y[firstYDiff]} ref=${ref[refOff + firstYDiff]}');
      }
      if (firstUDiff >= 0) {
        final w2 = uvW;
        print('      U first diff @byte $firstUDiff '
            '(r=${firstUDiff ~/ w2} c=${firstUDiff % w2}) '
            'dart=${u[firstUDiff]} ref=${ref[refOff + yLen + firstUDiff]}');
      }
      if (firstVDiff >= 0) {
        final w2 = uvW;
        print('      V first diff @byte $firstVDiff '
            '(r=${firstVDiff ~/ w2} c=${firstVDiff % w2}) '
            'dart=${v[firstVDiff]} ref=${ref[refOff + yLen + uvLen + firstVDiff]}');
      }
      refOff += yLen + 2 * uvLen;
    }
  }
}
