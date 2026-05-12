import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/constants/coef_probs.dart';
import 'package:test/test.dart';

import 'token_encoder_helper.dart';

void main() {
  group('decodeMbTokens', () {
    test('all-zero macroblock (Y2 present)', () {
      final probs = Uint8List.fromList(defaultCoefProbs);
      final enc = TokenEncoder(probs);

      // Y2 (block 24): type=1, startN=0, ctx=0.
      enc.encodeBlock(
        blockType: 1,
        startN: 0,
        initialCtx: 0,
        coeffs: List<int>.filled(16, 0),
      );
      // 16 Y blocks: type=0, startN=1, ctx=0.
      for (int i = 0; i < 16; i++) {
        enc.encodeBlock(
          blockType: 0,
          startN: 1,
          initialCtx: 0,
          coeffs: List<int>.filled(16, 0),
        );
      }
      // 8 UV blocks: type=2, startN=0, ctx=0.
      for (int i = 0; i < 8; i++) {
        enc.encodeBlock(
          blockType: 2,
          startN: 0,
          initialCtx: 0,
          coeffs: List<int>.filled(16, 0),
        );
      }
      final bytes = enc.enc.finish();

      final qcoeff = Int16List(400);
      final eobs = Uint8List(25);
      final ctx = EntropyContext();
      final eobTotal = decodeMbTokens(
        bc: BoolDecoder(bytes),
        coefProbs: probs,
        is4x4: false,
        context: ctx,
        qcoeff: qcoeff,
        eobs: eobs,
      );

      // libvpx accounting: Y2 nz=0 contributes -16, then each Y block adds
      // (nonzeros + skipDc) AFTER the += skipDc, so the 16 all-zero Y blocks
      // contribute 16 * 1 = 16. UV adds 0. Total = 0.
      expect(eobTotal, equals(0));
      for (int i = 0; i < 25; i++) {
        expect(eobs[i], equals(i < 16 ? 1 : 0));
      }
      for (int i = 0; i < 400; i++) {
        expect(qcoeff[i], equals(0));
      }
      // Above/left contexts must all be 0.
      for (int i = 0; i < 9; i++) {
        expect(ctx.above[i], equals(0));
        expect(ctx.left[i], equals(0));
      }
    });

    test('single +1 in luma block 0 at scan position 1', () {
      final probs = Uint8List.fromList(defaultCoefProbs);
      final enc = TokenEncoder(probs);

      // Y2 all-zero.
      enc.encodeBlock(
        blockType: 1,
        startN: 0,
        initialCtx: 0,
        coeffs: List<int>.filled(16, 0),
      );
      // Y block 0: skipDc=1, so the decoder starts at scan position 1
      // (band kBands[1]=1). Place +1 at natural-scan pos 1, which the
      // decoder will write to raster index kZigzag[1] = 1.
      final yCoeffs = List<int>.filled(16, 0);
      yCoeffs[1] = 1;
      enc.encodeBlock(
        blockType: 0,
        startN: 1,
        initialCtx: 0,
        coeffs: yCoeffs,
      );
      // Remaining Y blocks all-zero with correct simulated contexts.
      final aboveSim = List<int>.filled(9, 0);
      final leftSim = List<int>.filled(9, 0);
      aboveSim[0] = 1;
      leftSim[0] = 1;
      for (int i = 1; i < 16; i++) {
        final aIdx = i & 3;
        final lIdx = (i & 0xc) >> 2;
        final ctxI = aboveSim[aIdx] + leftSim[lIdx];
        enc.encodeBlock(
          blockType: 0,
          startN: 1,
          initialCtx: ctxI,
          coeffs: List<int>.filled(16, 0),
        );
        aboveSim[aIdx] = 0;
        leftSim[lIdx] = 0;
      }
      // UV blocks all-zero, contexts all 0.
      for (int i = 0; i < 8; i++) {
        enc.encodeBlock(
          blockType: 2,
          startN: 0,
          initialCtx: 0,
          coeffs: List<int>.filled(16, 0),
        );
      }

      final bytes = enc.enc.finish();
      final qcoeff = Int16List(400);
      final eobs = Uint8List(25);
      final ctx = EntropyContext();
      decodeMbTokens(
        bc: BoolDecoder(bytes),
        coefProbs: probs,
        is4x4: false,
        context: ctx,
        qcoeff: qcoeff,
        eobs: eobs,
      );

      // +1 lands at raster index 1 of block 0.
      expect(qcoeff[1], equals(1));
      expect(qcoeff[0], equals(0));
      // Decoder returned nz=2 for block 0; eobs[0] = nz + skipDc = 3.
      expect(eobs[0], equals(3));
      // Other Y blocks all-zero: nz=0 + skipDc=1 = 1.
      for (int i = 1; i < 16; i++) {
        expect(eobs[i], equals(1));
      }
    });
  });
}
