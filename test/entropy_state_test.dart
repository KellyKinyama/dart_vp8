// Tests for persistent entropy state across frames in `parseFrameHeader`.

import 'dart:typed_data';

import 'package:dart_vp8/src/constants/coef_probs.dart';
import 'package:dart_vp8/src/constants/mode_mv_probs.dart';
import 'package:dart_vp8/src/frame_header.dart';
import 'package:test/test.dart';

import 'bool_encoder_helper.dart';

/// Minimal inter-frame header byte stream that lets the decoder run
/// through the entropy / mode / mv prob update sections (with NO updates
/// transmitted) and stops there. We don't care about the per-MB bytes
/// after — we never call decode() on the result, only parseFrameHeader().
Uint8List buildInterHeaderForParsing() {
  final enc = BoolEncoder();
  enc.write(0, 128); // seg.enabled
  enc.write(0, 128); // lf.type
  enc.writeLiteral(0, 6); // lf.level
  enc.writeLiteral(0, 3); // lf.sharpness
  enc.write(0, 128); // lf.modeRefDeltaEnabled
  enc.writeLiteral(0, 2); // log2NumDctPartitions
  enc.writeLiteral(0, 7); // yAcQi
  for (int i = 0; i < 5; i++) {
    enc.write(0, 128); // delta-q flags
  }
  // refreshGolden=true, refreshAltref=true (so no copyBufferTo* fields).
  enc.write(1, 128);
  enc.write(1, 128);
  enc.write(0, 128); // signBiasGolden
  enc.write(0, 128); // signBiasAltref
  enc.write(0, 128); // refreshEntropyProbs = false
  enc.write(1, 128); // refreshLastFrame = true
  // Coef-prob updates: 1056 "no update" bits.
  for (int i = 0; i < blockTypes; i++) {
    for (int j = 0; j < coefBands; j++) {
      for (int k = 0; k < prevCoefContexts; k++) {
        for (int l = 0; l < entropyNodes; l++) {
          enc.write(0, coefUpdateProbs[coefProbIndex(i, j, k, l)]);
        }
      }
    }
  }
  enc.write(0, 128); // mbNoCoeffSkip = false
  enc.writeLiteral(128, 8); // probIntra
  enc.writeLiteral(128, 8); // probLast
  enc.writeLiteral(128, 8); // probGf
  enc.write(0, 128); // ymode update flag = no
  enc.write(0, 128); // uvmode update flag = no
  for (int ctx = 0; ctx < 2; ctx++) {
    for (int i = 0; i < 19; i++) {
      enc.write(0, mvUpdateProbs[ctx * 19 + i]);
    }
  }
  final firstPart = enc.finish();
  final int sizeField = (firstPart.length << 5) | (1 << 4) | 1;
  return Uint8List.fromList(<int>[
    sizeField & 0xff,
    (sizeField >> 8) & 0xff,
    (sizeField >> 16) & 0xff,
    ...firstPart,
    0xff,
    0xff,
    0xff,
    0xff,
  ]);
}

void main() {
  group('EntropyState', () {
    test('inter frame without prior state seeds from defaults', () {
      final frame = buildInterHeaderForParsing();
      final h = parseFrameHeader(frame);
      // No probs were updated and no priorState passed, so output equals
      // VP8 defaults.
      expect(h.coefProbs, equals(defaultCoefProbs));
      expect(h.yModeProb, equals(defaultYModeProb));
      expect(h.uvModeProb, equals(defaultUvModeProb));
      expect(h.mvContext, equals(defaultMvContext));
    });

    test('inter frame with prior state seeds from prior, not defaults', () {
      final state = EntropyState();
      // Mutate persistent state to non-default values.
      state.coefProbs.fillRange(0, state.coefProbs.length, 42);
      state.yModeProb.fillRange(0, state.yModeProb.length, 99);
      state.uvModeProb.fillRange(0, state.uvModeProb.length, 88);
      state.mvContext.fillRange(0, state.mvContext.length, 77);

      final frame = buildInterHeaderForParsing();
      final h = parseFrameHeader(frame, priorState: state);

      // Frame transmitted no updates -> output equals priorState exactly.
      expect(h.coefProbs.every((v) => v == 42), isTrue);
      expect(h.yModeProb.every((v) => v == 99), isTrue);
      expect(h.uvModeProb.every((v) => v == 88), isTrue);
      expect(h.mvContext.every((v) => v == 77), isTrue);
    });

    test('keyframe ignores priorState (reseeds from defaults)', () {
      // Build a tiny keyframe payload (we just need the entropy section
      // to be a valid no-update stream). Easiest path: reuse the test
      // helper from decoder_test, but we have a dependency loop. Simpler:
      // construct a valid keyframe inline.
      final enc = BoolEncoder();
      enc.write(0, 128); // colorSpace
      enc.write(0, 128); // clampingType
      enc.write(0, 128); // seg.enabled
      enc.write(0, 128); // lf.type
      enc.writeLiteral(0, 6); // lf.level
      enc.writeLiteral(0, 3); // lf.sharpness
      enc.write(0, 128); // lf.modeRefDeltaEnabled\
      enc.writeLiteral(0, 2); // log2NumDctPartitions
      enc.writeLiteral(0, 7); // yAcQi
      for (int i = 0; i < 5; i++) {
        enc.write(0, 128); // delta-q flags
      }
      enc.write(0, 128); // refreshEntropyProbs
      // Coef-prob updates: 1056 "no update" bits.
      for (int i = 0; i < blockTypes; i++) {
        for (int j = 0; j < coefBands; j++) {
          for (int k = 0; k < prevCoefContexts; k++) {
            for (int l = 0; l < entropyNodes; l++) {
              enc.write(0, coefUpdateProbs[coefProbIndex(i, j, k, l)]);
            }
          }
        }
      }
      enc.write(0, 128); // mbNoCoeffSkip = false
      // (Keyframes have no probIntra/Last/Gf/ymode/uvmode/mv-update fields.)
      final firstPart = enc.finish();
      final int sizeField = (firstPart.length << 5) | (1 << 4) | 0;
      final bytes = <int>[
        sizeField & 0xff,
        (sizeField >> 8) & 0xff,
        (sizeField >> 16) & 0xff,
        // Sync code + 16x16 dims.
        0x9d, 0x01, 0x2a,
        16, 0, 16, 0,
        ...firstPart,
        0xff, 0xff, 0xff, 0xff,
      ];

      final state = EntropyState()..coefProbs.fillRange(0, 1056, 42);
      final h = parseFrameHeader(Uint8List.fromList(bytes), priorState: state);

      // Keyframe must have re-seeded from defaults, ignoring priorState.
      expect(h.coefProbs, equals(defaultCoefProbs));
    });
  });
}
