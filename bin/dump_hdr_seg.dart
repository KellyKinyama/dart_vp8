import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/frame_header.dart';

void main(List<String> args) {
  final name = args.isEmpty ? 'vp80-00-comprehensive-013' : args[0];
  final frame = args.length > 1 ? int.parse(args[1]) : 1;
  final ivf = File('test/fixtures/$name.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  for (int f = 0; f <= frame; f++) {
    final ivfFrame = reader.nextFrame();
    if (ivfFrame == null) break;
    if (f == frame) {
      final hdr = parseFrameHeader(ivfFrame.data);
      print('frame=$f kf=${hdr.isKeyFrame}');
      print(' qi: yAc=${hdr.quantizer.yAcQi} y1Dc=${hdr.quantizer.y1DcDelta} '
          'y2Dc=${hdr.quantizer.y2DcDelta} y2Ac=${hdr.quantizer.y2AcDelta} '
          'uvDc=${hdr.quantizer.uvDcDelta} uvAc=${hdr.quantizer.uvAcDelta}');
      print(' seg.enabled=${hdr.segmentation.enabled} '
          'absDelta=${hdr.segmentation.absDelta}');
      print(' seg.featureData[altQ]=${hdr.segmentation.featureData[MbLvl.altQ]}');
      print(' seg.featureData[altLf]=${hdr.segmentation.featureData[MbLvl.altLf]}');
      print(' lf=${hdr.loopFilter.level} type=${hdr.loopFilter.type}');
    }
  }
}
