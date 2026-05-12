// End-to-end tests for the Stage 7A decoder pipeline.
//
// Builds tiny synthetic keyframes with `BoolEncoder` and verifies that
// `Vp8Decoder.decode` reproduces the expected reconstructed pixels.

import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
// ignore: implementation_imports
import 'package:dart_vp8/src/constants/coef_probs.dart';
// ignore: implementation_imports
import 'package:dart_vp8/src/constants/mode_mv_probs.dart';
import 'package:test/test.dart';

import 'bool_encoder_helper.dart';

/// Build a minimal keyframe with all macroblocks set to DC_PRED Y / DC_PRED
/// UV and `skip_coeff=true`. No segmentation, no loop filter, single token
/// partition. Quantizer index = 0.
Uint8List buildSkippedKeyframe({
  required int width,
  required int height,
  int yMode = dcPredM,
  int uvMode = dcPredM,
  int lfLevel = 0,
  int log2NumDctPartitions = 0,
  bool useBPred = false,
  int bMode = 0, // valid only when useBPred is true
}) {
  final int mbCols = (width + 15) >> 4;
  final int mbRows = (height + 15) >> 4;
  final int totalMbs = mbCols * mbRows;

  final enc = BoolEncoder();

  // -- Compressed header --
  enc.write(0, 128); // color_space
  enc.write(0, 128); // clamping_type
  enc.write(0, 128); // seg.enabled
  enc.write(0, 128); // lf.type (normal)
  enc.writeLiteral(lfLevel, 6); // lf.level
  enc.writeLiteral(0, 3); // lf.sharpness
  enc.write(0, 128); // lf.modeRefDeltaEnabled
  enc.writeLiteral(log2NumDctPartitions, 2);
  enc.writeLiteral(0, 7); // yAcQi = 0 (smallest q -> finest)
  for (int i = 0; i < 5; i++) {
    enc.write(0, 128); // delta_q flag = no delta
  }
  enc.write(0, 128); // refreshEntropyProbs

  // Coef-prob update flags: 4*8*3*11 = 1056 "no update" bits.
  for (int i = 0; i < blockTypes; i++) {
    for (int j = 0; j < coefBands; j++) {
      for (int k = 0; k < prevCoefContexts; k++) {
        for (int l = 0; l < entropyNodes; l++) {
          final int idx = coefProbIndex(i, j, k, l);
          enc.write(0, coefUpdateProbs[idx]);
        }
      }
    }
  }

  enc.write(1, 128); // mbNoCoeffSkip = true
  enc.writeLiteral(255, 8); // probSkipFalse = 255

  // -- Mode info: per-MB --
  // kfYModeProb = [145, 156, 163, 128]; tree:
  //   [-bPred, 2, 4, 6, -DC, -V, -H, -TM]
  // kfUvModeProb = [142, 114, 183]; tree:
  //   [-DC, 2, -V, 4, -H, -TM]
  void writeYMode(int m) {
    switch (m) {
      case dcPredM:
        enc.write(1, 145);
        enc.write(0, 156);
        enc.write(0, 163);
      case vPredM:
        enc.write(1, 145);
        enc.write(0, 156);
        enc.write(1, 163);
      case hPredM:
        enc.write(1, 145);
        enc.write(1, 156);
        enc.write(0, 128);
      case tmPredM:
        enc.write(1, 145);
        enc.write(1, 156);
        enc.write(1, 128);
      default:
        throw ArgumentError('unsupported y mode in test helper: $m');
    }
  }

  void writeUvMode(int m) {
    switch (m) {
      case dcPredM:
        enc.write(0, 142);
      case vPredM:
        enc.write(1, 142);
        enc.write(0, 114);
      case hPredM:
        enc.write(1, 142);
        enc.write(1, 114);
        enc.write(0, 183);
      case tmPredM:
        enc.write(1, 142);
        enc.write(1, 114);
        enc.write(1, 183);
      default:
        throw ArgumentError('unsupported uv mode in test helper: $m');
    }
  }

  for (int mb = 0; mb < totalMbs; mb++) {
    enc.write(1, 255); // skipCoeff = true
    if (useBPred) {
      // Emit Y mode = B_PRED. Tree: [-bPred, 2, 4, 6, -DC, -V, -H, -TM]
      // kfYModeProb = [145, 156, 163, 128]. B_PRED = bit 0 at root.
      enc.write(0, 145);
      // 16 B-modes. For all-bDcPred, above/left always resolve to bDcPred,
      // so every block uses kfBmodeProb[bDcPred][bDcPred] = [231, ...].
      // bmodeTree[0] = 0 (leaf=bDcPred), so a single 0 bit emits bDcPred.
      if (bMode != 0) {
        throw UnimplementedError('test helper supports B_DC_PRED only');
      }
      for (int i = 0; i < 16; i++) {
        enc.write(0, 231);
      }
    } else {
      writeYMode(yMode);
    }
    writeUvMode(uvMode);
  }

  final Uint8List firstPart = enc.finish();
  final int firstPartLen = firstPart.length;

  // Build token partitions. For numParts > 1 we need a (numParts-1)-entry
  // 3-byte size table followed by the partition payloads. Each payload is
  // 2 bytes of 0xff (safe filler -- decoders read but never consume any
  // token tree because every MB is marked skipCoeff).
  final int numParts = 1 << log2NumDctPartitions;
  final tokenBytes = <int>[];
  for (int i = 0; i < numParts - 1; i++) {
    // Each non-last partition is 2 bytes.
    tokenBytes.addAll(<int>[2, 0, 0]);
  }
  for (int i = 0; i < numParts; i++) {
    tokenBytes.addAll(<int>[0xff, 0xff]);
  }

  // -- Outer frame wrapper --
  // 3-byte tag.
  final int sizeField = (firstPartLen << 5) | (1 << 4); // show=1, kf
  final out = <int>[
    sizeField & 0xff,
    (sizeField >> 8) & 0xff,
    (sizeField >> 16) & 0xff,
    // Keyframe sync code.
    0x9d, 0x01, 0x2a,
    // width (14) | hscale (2)
    width & 0xff,
    (width >> 8) & 0x3f,
    // height (14) | vscale (2)
    height & 0xff,
    (height >> 8) & 0x3f,
    ...firstPart,
    ...tokenBytes,
    // Trailing padding (in case of over-read).
    0xff, 0xff, 0xff, 0xff,
  ];
  return Uint8List.fromList(out);
}

/// Build a minimal *inter* VP8 frame: every MB is ZEROMV referencing
/// LAST_FRAME with `skip_coeff = true`. No segmentation, no loop filter,
/// single token partition. Quantizer index = 0.
///
/// The frame is dimensioned identically to the keyframe that preceded it
/// (the decoder reuses its existing output buffer). Width/height arguments
/// are used only to compute the MB grid.
Uint8List buildZeroMvInterFrame({
  required int width,
  required int height,
  bool refreshGolden = true,
  bool refreshAltref = true,
  bool refreshLast = true,
  int copyBufferToGf = 0,
  int copyBufferToArf = 0,
  bool useNewMv = false,
}) {
  final int mbCols = (width + 15) >> 4;
  final int mbRows = (height + 15) >> 4;
  final int totalMbs = mbCols * mbRows;

  final enc = BoolEncoder();

  // Compressed header.
  enc.write(0, 128); // seg.enabled = false
  enc.write(0, 128); // lf.type = normal
  enc.writeLiteral(0, 6); // lf.level = 0
  enc.writeLiteral(0, 3); // lf.sharpness
  enc.write(0, 128); // lf.modeRefDeltaEnabled
  enc.writeLiteral(0, 2); // log2NumDctPartitions = 0
  enc.writeLiteral(0, 7); // yAcQi
  for (int i = 0; i < 5; i++) {
    enc.write(0, 128); // no delta-q
  }
  // Inter-frame ref management.
  enc.write(refreshGolden ? 1 : 0, 128); // refreshGoldenFrame
  enc.write(refreshAltref ? 1 : 0, 128); // refreshAltrefFrame
  if (!refreshGolden) {
    enc.writeLiteral(copyBufferToGf, 2); // copyBufferToGf
  }
  if (!refreshAltref) {
    enc.writeLiteral(copyBufferToArf, 2); // copyBufferToArf
  }
  enc.write(0, 128); // signBiasGolden
  enc.write(0, 128); // signBiasAltref
  enc.write(0, 128); // refreshEntropyProbs
  enc.write(refreshLast ? 1 : 0, 128); // refreshLastFrame

  // Coef-prob updates (1056 "no update" bits).
  for (int i = 0; i < blockTypes; i++) {
    for (int j = 0; j < coefBands; j++) {
      for (int k = 0; k < prevCoefContexts; k++) {
        for (int l = 0; l < entropyNodes; l++) {
          enc.write(0, coefUpdateProbs[coefProbIndex(i, j, k, l)]);
        }
      }
    }
  }

  enc.write(1, 128); // mbNoCoeffSkip = true
  enc.writeLiteral(255, 8); // probSkipFalse = 255

  // Inter-frame mode/MV prob fields.
  enc.writeLiteral(128, 8); // probIntra
  enc.writeLiteral(128, 8); // probLast
  enc.writeLiteral(128, 8); // probGf
  enc.write(0, 128); // ymode prob update flag = no
  enc.write(0, 128); // uvmode prob update flag = no

  // 38 MV-prob "no update" bits (2 contexts of 19 probs each).
  for (int ctx = 0; ctx < 2; ctx++) {
    for (int i = 0; i < 19; i++) {
      enc.write(0, mvUpdateProbs[ctx * 19 + i]);
    }
  }

  // Per-MB: skip + inter + LAST + (ZEROMV or NEWMV with zero delta).
  for (int mb = 0; mb < totalMbs; mb++) {
    enc.write(1, 255); // skipCoeff = true
    enc.write(1, 128); // inter (not intra) -- against probIntra=128
    enc.write(0, 128); // refFrame: 0 vs probLast=128 -> LAST
    // mv_ref tree: with all-INTRA neighbours, cnt = [0,0,0,0], so the
    // mode-tree probs are vp8_mode_contexts[0] = [7, 1, 1, 143].
    if (useNewMv) {
      enc.write(1, 7); // NEAREST/NEAR/ZERO/NEW path (not ZEROMV leaf)
      enc.write(1, 1); // not NEAREST
      enc.write(1, 1); // not NEAR
      enc.write(0, 143); // NEWMV (vs SPLITMV)
      // Read MV (row, col): both components zero-delta.
      // Row component: short=0 vs 162; small-tree mag 0 = 0,0,0
      //   vs probs row[2..4] = 225,146,172.
      enc.write(0, 162);
      enc.write(0, 225);
      enc.write(0, 146);
      enc.write(0, 172);
      // Col component: short=0 vs 164; small-tree mag 0 = 0,0,0
      //   vs probs col[2..4] = 204,170,119.
      enc.write(0, 164);
      enc.write(0, 204);
      enc.write(0, 170);
      enc.write(0, 119);
    } else {
      enc.write(0, 7); // ZEROMV leaf
    }
  }

  final Uint8List firstPart = enc.finish();
  final int firstPartLen = firstPart.length;

  final int sizeField = (firstPartLen << 5) | (1 << 4) | 1; // show=1, inter
  final out = <int>[
    sizeField & 0xff,
    (sizeField >> 8) & 0xff,
    (sizeField >> 16) & 0xff,
    ...firstPart,
    // Token partition payload (only 1 partition; size implicit).
    0xff, 0xff,
    // Trailing padding.
    0xff, 0xff, 0xff, 0xff,
  ];
  return Uint8List.fromList(out);
}

void main() {
  group('Vp8Decoder (Stage 7A)', () {
    test('decodes 16x16 single-MB DC_PRED skipped keyframe to all 128', () {
      final payload = buildSkippedKeyframe(width: 16, height: 16);
      final dec = Vp8Decoder();
      final frame = dec.decode(
        IvfFrame(0, payload),
      );
      expect(frame.width, 16);
      expect(frame.height, 16);
      expect(frame.isKeyFrame, isTrue);
      expect(frame.yStride, 16);
      expect(frame.uvStride, 8);
      for (final v in frame.y) {
        expect(v, 128);
      }
      for (final v in frame.u) {
        expect(v, 128);
      }
      for (final v in frame.v) {
        expect(v, 128);
      }
    });

    test('decodes 32x32 four-MB DC_PRED skipped keyframe to all 128', () {
      final payload = buildSkippedKeyframe(width: 32, height: 32);
      final dec = Vp8Decoder();
      final frame = dec.decode(
        IvfFrame(0, payload),
      );
      expect(frame.width, 32);
      expect(frame.height, 32);
      expect(frame.yStride, 32);
      expect(frame.uvStride, 16);
      // All planes should be 128 since no neighbours are ever available
      // when residuals are zero and inheritance is byte-128 fallback chains
      // (every MB reconstructed to all-128 propagates to all its
      // neighbours).
      for (final v in frame.y) {
        expect(v, 128);
      }
      for (final v in frame.u) {
        expect(v, 128);
      }
      for (final v in frame.v) {
        expect(v, 128);
      }
    });

    test('V_PRED keyframe replicates top border 127 across plane', () {
      final payload = buildSkippedKeyframe(
        width: 16,
        height: 16,
        yMode: vPredM,
        uvMode: vPredM,
      );
      final dec = Vp8Decoder();
      final frame = dec.decode(IvfFrame(0, payload));
      for (final v in frame.y) {
        expect(v, 127);
      }
      for (final v in frame.u) {
        expect(v, 127);
      }
      for (final v in frame.v) {
        expect(v, 127);
      }
    });

    test('H_PRED keyframe replicates left border 129 across plane', () {
      final payload = buildSkippedKeyframe(
        width: 16,
        height: 16,
        yMode: hPredM,
        uvMode: hPredM,
      );
      final dec = Vp8Decoder();
      final frame = dec.decode(IvfFrame(0, payload));
      for (final v in frame.y) {
        expect(v, 129);
      }
      for (final v in frame.u) {
        expect(v, 129);
      }
      for (final v in frame.v) {
        expect(v, 129);
      }
    });

    test('TM_PRED keyframe with no neighbours yields 129', () {
      // No-neighbour TM: above=127, left=129, topLeft=127.
      // pixel = clip(left + above - topLeft) = clip(129+127-127) = 129.
      final payload = buildSkippedKeyframe(
        width: 16,
        height: 16,
        yMode: tmPredM,
        uvMode: tmPredM,
      );
      final dec = Vp8Decoder();
      final frame = dec.decode(IvfFrame(0, payload));
      for (final v in frame.y) {
        expect(v, 129);
      }
      for (final v in frame.u) {
        expect(v, 129);
      }
      for (final v in frame.v) {
        expect(v, 129);
      }
    });

    test('non-zero loop filter level on flat frame is a no-op', () {
      final payload = buildSkippedKeyframe(
        width: 32,
        height: 32,
        lfLevel: 32,
      );
      final dec = Vp8Decoder();
      final frame = dec.decode(IvfFrame(0, payload));
      // Diagnostic: report first mismatch with full coordinates.
      for (int i = 0; i < frame.y.length; i++) {
        if (frame.y[i] != 128) {
          fail('Y[$i] (row ${i ~/ frame.yStride}, '
              'col ${i % frame.yStride}) = ${frame.y[i]}, expected 128');
        }
      }
      for (int i = 0; i < frame.u.length; i++) {
        if (frame.u[i] != 128) {
          fail('U[$i] = ${frame.u[i]}');
        }
      }
      for (int i = 0; i < frame.v.length; i++) {
        if (frame.v[i] != 128) {
          fail('V[$i] = ${frame.v[i]}');
        }
      }
    });

    test('malformed inter frame throws', () {
      // Build a valid keyframe, then flip the keyframe bit (bit 0 of byte
      // 0) to mark the frame as an inter frame. The bitstream that
      // follows is no longer a valid inter-frame layout, so the decoder
      // throws somewhere during compressed-header parsing or mode decode.
      final kf = buildSkippedKeyframe(width: 16, height: 16);
      kf[0] |= 1;
      // Inter frames are decoded only after a real keyframe has been
      // seen, so first prime the decoder with a valid keyframe.
      final dec = Vp8Decoder();
      dec.decode(IvfFrame(0, buildSkippedKeyframe(width: 16, height: 16)));
      expect(
        () => dec.decode(IvfFrame(0, kf)),
        throwsA(isA<FormatException>()),
      );
    });

    test('B_PRED keyframe with all-B_DC_PRED blocks decodes', () {
      // Each 4x4 block decodes as B_DC_PRED = (sum(above[0..3]) +
      // sum(left[0..3]) + 4) >> 3. The top-row of 4x4 blocks sees
      // above=border 127 and left chains from 129/128, so rows 0..3 are
      // all 128. Subsequent block rows see above=128 (reconstructed) but
      // still left=border 129 at the leftmost column, so they propagate
      // 129 instead of 128 -- this is the correct VP8 behaviour and
      // matches libvpx exactly. We assert the top block row is 128 and
      // that nothing throws.
      final payload = buildSkippedKeyframe(
        width: 16,
        height: 16,
        useBPred: true,
        bMode: 0, // bDcPred
        uvMode: dcPredM,
      );
      final dec = Vp8Decoder();
      final frame = dec.decode(IvfFrame(0, payload));
      expect(frame.width, 16);
      expect(frame.height, 16);
      // Top 4 rows of Y are all 128.
      for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 16; col++) {
          expect(frame.y[row * frame.yStride + col], 128,
              reason: 'Y[$row,$col]');
        }
      }
      // UV uses DC_PRED MB-level prediction -> all 128.
      for (final v in frame.u) {
        expect(v, 128);
      }
      for (final v in frame.v) {
        expect(v, 128);
      }
    });

    test('multi-partition (2) skipped keyframe still decodes to 128', () {
      final payload = buildSkippedKeyframe(
        width: 32,
        height: 32,
        log2NumDctPartitions: 1,
      );
      final dec = Vp8Decoder();
      final frame = dec.decode(IvfFrame(0, payload));
      expect(frame.width, 32);
      expect(frame.height, 32);
      for (final v in frame.y) {
        expect(v, 128);
      }
    });

    test('multi-partition (4) skipped keyframe still decodes to 128', () {
      final payload = buildSkippedKeyframe(
        width: 32,
        height: 32,
        log2NumDctPartitions: 2,
      );
      final dec = Vp8Decoder();
      final frame = dec.decode(IvfFrame(0, payload));
      for (final v in frame.y) {
        expect(v, 128);
      }
    });

    test('inter frame with ZEROMV referencing LAST reproduces keyframe', () {
      final kf = buildSkippedKeyframe(width: 16, height: 16);
      final inter = buildZeroMvInterFrame(width: 16, height: 16);
      final dec = Vp8Decoder();
      final kfDecoded = dec.decode(IvfFrame(0, kf));
      // Sanity check.
      expect(kfDecoded.isKeyFrame, isTrue);
      for (final v in kfDecoded.y) {
        expect(v, 128);
      }
      final interDecoded = dec.decode(IvfFrame(1, inter));
      expect(interDecoded.isKeyFrame, isFalse);
      expect(interDecoded.width, 16);
      expect(interDecoded.height, 16);
      // ZEROMV + no residual => copy of LAST (= the keyframe).
      for (final v in interDecoded.y) {
        expect(v, 128);
      }
      for (final v in interDecoded.u) {
        expect(v, 128);
      }
      for (final v in interDecoded.v) {
        expect(v, 128);
      }
    });

    test('inter frame chain: 4 frames all ZEROMV stay constant', () {
      // Use 16x16 (single MB) so the neighbour-count context for the MV
      // mode tree is always [0,0,0,0] and the test encoder's hard-coded
      // probability matches the decoder.
      final dec = Vp8Decoder();
      dec.decode(IvfFrame(0, buildSkippedKeyframe(width: 16, height: 16)));
      for (int i = 1; i < 4; i++) {
        final f = dec
            .decode(IvfFrame(i, buildZeroMvInterFrame(width: 16, height: 16)));
        for (final v in f.y) {
          expect(v, 128);
        }
        for (final v in f.u) {
          expect(v, 128);
        }
        for (final v in f.v) {
          expect(v, 128);
        }
      }
    });

    test('inter frame with copy_buffer_to_gf=1 (LAST->GOLDEN) decodes', () {
      // Verifies the ref-management bits are parsed and the copy path in
      // _updateReferenceBuffers doesn't blow up. Without refreshing GF or
      // ARF, the decoder reads two extra 2-bit copy fields.
      final dec = Vp8Decoder();
      dec.decode(IvfFrame(0, buildSkippedKeyframe(width: 16, height: 16)));
      final f = dec.decode(IvfFrame(
        1,
        buildZeroMvInterFrame(
          width: 16,
          height: 16,
          refreshGolden: false,
          refreshAltref: false,
          copyBufferToGf: 1, // LAST -> GOLDEN
          copyBufferToArf: 2, // GOLDEN -> ALTREF
        ),
      ));
      expect(f.isKeyFrame, isFalse);
      for (final v in f.y) {
        expect(v, 128);
      }
    });

    test('inter frame without refreshing LAST keeps prior LAST', () {
      // refreshLast=false: the next inter frame must still see the
      // keyframe as LAST. Decoding a follow-up ZEROMV frame should
      // therefore still produce the keyframe contents.
      final dec = Vp8Decoder();
      dec.decode(IvfFrame(0, buildSkippedKeyframe(width: 16, height: 16)));
      dec.decode(IvfFrame(
        1,
        buildZeroMvInterFrame(
          width: 16,
          height: 16,
          refreshLast: false,
        ),
      ));
      final f = dec.decode(IvfFrame(
        2,
        buildZeroMvInterFrame(width: 16, height: 16),
      ));
      for (final v in f.y) {
        expect(v, 128);
      }
    });

    test('inter frame with NEWMV (zero delta) decodes', () {
      // Exercises the NEWMV branch of the mv_ref tree and the readMv
      // path. A zero MV delta against a flat keyframe still yields all
      // 128 (constant input survives sub-pel filtering trivially).
      final dec = Vp8Decoder();
      dec.decode(IvfFrame(0, buildSkippedKeyframe(width: 16, height: 16)));
      final f = dec.decode(IvfFrame(
        1,
        buildZeroMvInterFrame(width: 16, height: 16, useNewMv: true),
      ));
      expect(f.isKeyFrame, isFalse);
      for (final v in f.y) {
        expect(v, 128);
      }
      for (final v in f.u) {
        expect(v, 128);
      }
      for (final v in f.v) {
        expect(v, 128);
      }
    });
  });
}
