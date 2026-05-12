import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/frame_header.dart' show parseFrameHeader;

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-013' : args[0];
  final maxFrames = args.length >= 2 ? int.parse(args[1]) : 3;
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  for (int i = 0; i < maxFrames; i++) {
    final f = reader.nextFrame();
    if (f == null) break;
    final h = parseFrameHeader(f.data);
    print('Frame $i: kf=${h.isKeyFrame} '
        'w=${h.width} h=${h.height} '
        'numParts=${1 << h.log2NumDctPartitions} '
        'qi=${h.quantizer.yAcQi} lf=${h.loopFilter.level} '
        'mbSkip=${h.mbNoCoeffSkip}');
  }
}
