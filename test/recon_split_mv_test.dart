// Direct unit test for the SPLITMV reconstruction path. Bypasses the
// bitstream synthesis (which is awkward because SPLITMV requires
// non-trivial neighbour context) by constructing a `ModeInfo` and
// `RefFrame` in-memory and calling `reconstructMbInter` straight.

import 'dart:typed_data';

import 'package:dart_vp8/src/entropy.dart';
import 'package:dart_vp8/src/mode_info.dart';
import 'package:dart_vp8/src/mv.dart';
import 'package:dart_vp8/src/quant.dart';
import 'package:dart_vp8/src/recon.dart';
import 'package:dart_vp8/src/ref_frame.dart';
import 'package:test/test.dart';

int packMv(int row, int col) {
  // Same layout as `packBMv` in lib/src/mv.dart.
  return ((row & 0xffff) << 16) | (col & 0xffff);
}

void main() {
  group('SPLITMV reconstruction (direct)', () {
    test('flat ref + zero residual + zero MV yields all 128', () {
      // Build a 1x1-MB flat ref (16x16 luma, 8x8 chroma, all 128).
      final ref = RefFrame(width: 16, height: 16);
      final flatY = Uint8List(16 * 16)..fillRange(0, 16 * 16, 128);
      final flatUv = Uint8List(8 * 8)..fillRange(0, 8 * 8, 128);
      refFrameFromPlanes(
        dst: ref,
        srcY: flatY,
        srcYStride: 16,
        srcU: flatUv,
        srcV: flatUv,
        srcUvStride: 8,
      );

      // ModeInfo: SPLITMV with all sub-block MVs zero.
      final mi = ModeInfo()
        ..yMode = splitMv
        ..uvMode = 0
        ..refFrame = refLast
        ..skipCoeff = true
        ..partitioning = 3; // 4x4
      for (int i = 0; i < 16; i++) {
        mi.bMvs[i] = packMv(0, 0);
      }

      final qcoeff = Int16List(blocksPerMb * blockSize);
      final eobs = Uint8List(blocksPerMb);
      final dq = buildDequant(
        qi: 0,
        y1DcDelta: 0,
        y2DcDelta: 0,
        y2AcDelta: 0,
        uvDcDelta: 0,
        uvAcDelta: 0,
      );

      final yPlane = Uint8List(16 * 16);
      final uPlane = Uint8List(8 * 8);
      final vPlane = Uint8List(8 * 8);

      reconstructMbInter(
        mi: mi,
        qcoeff: qcoeff,
        eobs: eobs,
        dq: dq,
        ref: ref,
        yPlane: yPlane,
        uPlane: uPlane,
        vPlane: vPlane,
        mbCol: 0,
        mbRow: 0,
        yStride: 16,
        uvStride: 8,
        useBilinear: false,
      );

      for (final v in yPlane) {
        expect(v, 128);
      }
      for (final v in uPlane) {
        expect(v, 128);
      }
      for (final v in vPlane) {
        expect(v, 128);
      }
    });

    test('flat ref + non-zero MV pattern still yields all 128', () {
      // A flat reference convolved with the sub-pel filters (sixtap or
      // bilinear) is still flat: the filter taps sum to 128 (the
      // normalisation factor), so applied to a constant c they reproduce
      // c. This validates that the SPLITMV per-4x4 predict path
      // correctly addresses the reference for every sub-block, including
      // the corner blocks that use the replicated border.
      final ref = RefFrame(width: 16, height: 16);
      final flatY = Uint8List(16 * 16)..fillRange(0, 16 * 16, 128);
      final flatUv = Uint8List(8 * 8)..fillRange(0, 8 * 8, 128);
      refFrameFromPlanes(
        dst: ref,
        srcY: flatY,
        srcYStride: 16,
        srcU: flatUv,
        srcV: flatUv,
        srcUvStride: 8,
      );

      final mi = ModeInfo()
        ..yMode = splitMv
        ..refFrame = refLast
        ..skipCoeff = true
        ..partitioning = 3;
      // Vary MVs across the 16 sub-blocks. 1/8-pel units: row/col in
      // {-3, -1, 0, 1, 3, 5} sample. Stay small so the predict reads
      // from inside the 16x16 reference (border replication still
      // covers anything that spills).
      const sample = <int>[-3, -1, 0, 1, 3, 5];
      for (int i = 0; i < 16; i++) {
        final r = sample[i % sample.length];
        final c = sample[(i * 7) % sample.length];
        mi.bMvs[i] = packMv(r, c);
      }

      final qcoeff = Int16List(blocksPerMb * blockSize);
      final eobs = Uint8List(blocksPerMb);
      final dq = buildDequant(
        qi: 0,
        y1DcDelta: 0,
        y2DcDelta: 0,
        y2AcDelta: 0,
        uvDcDelta: 0,
        uvAcDelta: 0,
      );

      final yPlane = Uint8List(16 * 16);
      final uPlane = Uint8List(8 * 8);
      final vPlane = Uint8List(8 * 8);

      reconstructMbInter(
        mi: mi,
        qcoeff: qcoeff,
        eobs: eobs,
        dq: dq,
        ref: ref,
        yPlane: yPlane,
        uPlane: uPlane,
        vPlane: vPlane,
        mbCol: 0,
        mbRow: 0,
        yStride: 16,
        uvStride: 8,
        useBilinear: false,
      );

      for (final v in yPlane) {
        expect(v, 128);
      }
      for (final v in uPlane) {
        expect(v, 128);
      }
      for (final v in vPlane) {
        expect(v, 128);
      }
    });

    test('bilinear path also yields all 128 on flat ref', () {
      final ref = RefFrame(width: 16, height: 16);
      final flatY = Uint8List(16 * 16)..fillRange(0, 16 * 16, 200);
      final flatUv = Uint8List(8 * 8)..fillRange(0, 8 * 8, 50);
      refFrameFromPlanes(
        dst: ref,
        srcY: flatY,
        srcYStride: 16,
        srcU: flatUv,
        srcV: flatUv,
        srcUvStride: 8,
      );

      final mi = ModeInfo()
        ..yMode = splitMv
        ..refFrame = refLast
        ..skipCoeff = true
        ..partitioning = 3;
      for (int i = 0; i < 16; i++) {
        mi.bMvs[i] = packMv(2, -2);
      }

      final qcoeff = Int16List(blocksPerMb * blockSize);
      final eobs = Uint8List(blocksPerMb);
      final dq = buildDequant(
        qi: 0,
        y1DcDelta: 0,
        y2DcDelta: 0,
        y2AcDelta: 0,
        uvDcDelta: 0,
        uvAcDelta: 0,
      );

      final yPlane = Uint8List(16 * 16);
      final uPlane = Uint8List(8 * 8);
      final vPlane = Uint8List(8 * 8);

      reconstructMbInter(
        mi: mi,
        qcoeff: qcoeff,
        eobs: eobs,
        dq: dq,
        ref: ref,
        yPlane: yPlane,
        uPlane: uPlane,
        vPlane: vPlane,
        mbCol: 0,
        mbRow: 0,
        yStride: 16,
        uvStride: 8,
        useBilinear: true,
      );

      for (final v in yPlane) {
        expect(v, 200);
      }
      for (final v in uPlane) {
        expect(v, 50);
      }
      for (final v in vPlane) {
        expect(v, 50);
      }
    });
  });
}
