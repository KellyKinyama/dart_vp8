import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/frame_header.dart';

void main() {
  final ivf =
      File('test/fixtures/vp80-00-comprehensive-010.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  EntropyState? prior;
  for (int f = 0; f < 26; f++) {
    final ivfFrame = reader.nextFrame();
    if (ivfFrame == null) break;
    final hdr = parseFrameHeader(ivfFrame.data, priorState: prior);
    print('f=$f kf=${hdr.isKeyFrame} refreshEnt=${hdr.refreshEntropyProbs} '
        'rL=${hdr.refreshLastFrame} rG=${hdr.refreshGoldenFrame} rA=${hdr.refreshAltrefFrame} '
        'cpyG=${hdr.copyBufferToGf} cpyA=${hdr.copyBufferToArf} '
        'sbG=${hdr.signBiasGolden} sbA=${hdr.signBiasAltref} qi=${hdr.quantizer.yAcQi}');
    prior ??= EntropyState();
    if (hdr.refreshEntropyProbs) {
      prior.commitFrom(hdr);
    } else if (hdr.isKeyFrame) {
      prior.resetToDefaults();
      prior.commitLfFrom(hdr);
    } else {
      prior.commitLfFrom(hdr);
    }
    prior.commitSegFrom(hdr);
  }
}
