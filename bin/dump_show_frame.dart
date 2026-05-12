import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/frame_header.dart';

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-018' : args[0];
  final max = args.length > 1 ? int.parse(args[1]) : 4;
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  for (int f = 0; f < max; f++) {
    final fr = reader.nextFrame();
    if (fr == null) break;
    final hdr = parseFrameHeader(fr.data);
    print('f=$f size=${fr.data.length} kf=${hdr.isKeyFrame} '
        'showFrame=${hdr.showFrame} version=${hdr.version} '
        'refreshLast=${hdr.refreshLastFrame} refGold=${hdr.refreshGoldenFrame} '
        'refArf=${hdr.refreshAltrefFrame}');
  }
}
