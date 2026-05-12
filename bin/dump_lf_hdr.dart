import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  for (int i = 0; i < 3; i++) {
    final f = reader.nextFrame()!;
    // Parse header on raw bytes for visibility.
    final hdr = parseFrameHeader(f.data);
    print('Frame $i: keyframe=${hdr.isKeyFrame} '
        'lf.level=${hdr.loopFilter.level} '
        'sharpness=${hdr.loopFilter.sharpness} '
        'type=${hdr.loopFilter.type} '
        'mrlfdEnable=${hdr.loopFilter.modeRefDeltaEnabled} '
        'modeRefUpdate=${hdr.loopFilter.modeRefDeltaUpdate} '
        'refDeltas=${hdr.loopFilter.refDeltas} '
        'modeDeltas=${hdr.loopFilter.modeDeltas}');
    dec.decode(f);
  }
}
