import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/ref_frame.dart';
import 'package:dart_vp8/src/inter_pred.dart';

void main() {
  // Decode frames 0 and 1 to get the reference frame for frame 2.
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  DecodedFrame? df1;
  for (int i = 0; i < 2; i++) {
    df1 = dec.decode(reader.nextFrame()!);
  }
  final ref = RefFrame(width: 176, height: 144);
  refFrameFromPlanes(
    dst: ref,
    srcY: df1!.y,
    srcYStride: df1.yStride,
    srcU: df1.u,
    srcV: df1.v,
    srcUvStride: df1.uvStride,
  );

  // MB(1,9) mv=(0, 226), so int col offset = 226 >> 3 = 28, sub-col = 2.
  // Source top-left = ref Y row (16 + 0) col (144 + 28) = (16, 172).
  final int srcOff = ref.yOrigin + 16 * ref.yStride + 172;

  // Predict 16x16 into a flat buffer.
  final dst = Uint8List(16 * 16);
  sixtapPredict16x16(ref.y, srcOff, ref.yStride, 2, 0, dst, 0, 16);

  // Print row 4 (frame row 20) of the prediction.
  print('MB(1,9) prediction row 4 (frame row 20):');
  print(dst.sublist(4 * 16, 5 * 16));

  // Also dump source area row 16 cols 168..183 of ref.
  print('Ref row 16 cols 168..183:');
  final int rowOff = ref.yOrigin + 16 * ref.yStride;
  print(ref.y.sublist(rowOff + 168, rowOff + 184));
  print('Ref row 17 cols 168..183:');
  final int rowOff17 = ref.yOrigin + 17 * ref.yStride;
  print(ref.y.sublist(rowOff17 + 168, rowOff17 + 184));
  print('Ref row 20 cols 168..183:');
  final int rowOff20 = ref.yOrigin + 20 * ref.yStride;
  print(ref.y.sublist(rowOff20 + 168, rowOff20 + 184));
}
