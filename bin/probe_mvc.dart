import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/frame_header.dart';

void main() {
  final ivf =
      File('test/fixtures/vp80-00-comprehensive-003.ivf').readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  EntropyState? prior;
  for (int f = 0; f <= 1; f++) {
    final ivfFrame = reader.nextFrame()!;
    final hdr = parseFrameHeader(ivfFrame.data, priorState: prior);
    print('frame $f mvc:');
    for (int ctx = 0; ctx < 2; ctx++) {
      final base = ctx * 19;
      final row = [for (int i = 0; i < 19; i++) hdr.mvContext[base + i]];
      print('  ctx$ctx: $row');
    }
    prior ??= EntropyState();
    if (hdr.refreshEntropyProbs) {
      prior.commitFrom(hdr);
    } else if (hdr.isKeyFrame) {
      prior.resetToDefaults();
      prior.commitLfFrom(hdr);
    } else {
      prior.commitLfFrom(hdr);
    }
  }
}
