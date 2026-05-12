import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:dart_vp8/src/constants/coef_probs.dart';
import 'package:dart_vp8/src/constants/mode_mv_probs.dart';
import 'package:test/test.dart';

import 'bool_encoder_helper.dart';

/// Build the 3-byte uncompressed tag.
List<int> _tag({
  required bool keyFrame,
  required int version,
  required bool showFrame,
  required int firstPartitionSize,
}) {
  final int word = ((keyFrame ? 0 : 1) & 1) |
      ((version & 7) << 1) |
      ((showFrame ? 1 : 0) << 4) |
      ((firstPartitionSize & 0x7ffff) << 5);
  return <int>[word & 0xff, (word >> 8) & 0xff, (word >> 16) & 0xff];
}

/// Build keyframe 7-byte block: sync code + sized fields.
List<int> _kfBlock({
  required int width,
  required int hScale,
  required int height,
  required int vScale,
}) {
  final int wRaw = (width & 0x3fff) | ((hScale & 3) << 14);
  final int hRaw = (height & 0x3fff) | ((vScale & 3) << 14);
  return <int>[
    0x9d,
    0x01,
    0x2a,
    wRaw & 0xff,
    (wRaw >> 8) & 0xff,
    hRaw & 0xff,
    (hRaw >> 8) & 0xff,
  ];
}

/// Encode the boolean portion of a keyframe header with all-default values
/// and no updates of any kind.
Uint8List _encodeMinimalKeyframeBoolPart() {
  final e = BoolEncoder();
  // color_space, clamping_type.
  e.write(0, 128);
  e.write(0, 128);
  // segmentation_enabled = 0.
  e.write(0, 128);
  // loop filter
  e.write(0, 128); // type = 0
  e.writeLiteral(20, 6); // level
  e.writeLiteral(3, 3); // sharpness
  e.write(0, 128); // modeRefDeltaEnabled = 0
  // log2NumDctPartitions = 0
  e.writeLiteral(0, 2);
  // quantizer
  e.writeLiteral(42, 7); // base Q
  for (int i = 0; i < 5; i++) {
    e.write(0, 128); // delta absent
  }
  // refresh_entropy_probs = 1 (so probs persist; we just test parsing).
  e.write(1, 128);
  // Coefficient probability updates: all-0 flags against the update probs.
  for (int t = 0; t < blockTypes; t++) {
    for (int b = 0; b < coefBands; b++) {
      for (int c = 0; c < prevCoefContexts; c++) {
        for (int n = 0; n < entropyNodes; n++) {
          e.write(0, coefUpdateProbs[coefProbIndex(t, b, c, n)]);
        }
      }
    }
  }
  // mb_no_coeff_skip = 0.
  e.write(0, 128);
  return e.finish();
}

/// Encode an inter-frame boolean portion with a few updates so we can
/// observe the parser handling them.
Uint8List _encodeInterframeBoolPart({
  required int probIntra,
  required int probLast,
  required int probGf,
  required List<int> updatedYMode,
}) {
  final e = BoolEncoder();
  // segmentation_enabled = 0
  e.write(0, 128);
  // loop filter
  e.write(1, 128); // simple LF
  e.writeLiteral(33, 6);
  e.writeLiteral(2, 3);
  e.write(0, 128);
  // log2NumDctPartitions = 1 -> 2 partitions
  e.writeLiteral(1, 2);
  // quant: yAcQi=50, y1DcDelta=-3 (others zero)
  e.writeLiteral(50, 7);
  e.write(1, 128); // y1DcDelta present
  e.writeLiteral(3, 4);
  e.write(1, 128); // sign
  e.write(0, 128); // y2DcDelta absent
  e.write(0, 128);
  e.write(0, 128);
  e.write(0, 128);

  // refresh_golden, refresh_alt, copy bits, sign biases
  e.write(0, 128); // refresh_golden = 0
  e.write(1, 128); // refresh_alt = 1
  // copy_buffer_to_gf because !refresh_golden
  e.writeLiteral(2, 2);
  // copy_buffer_to_arf skipped because refresh_alt=1
  e.write(1, 128); // sign_bias_golden
  e.write(0, 128); // sign_bias_altref

  e.write(0, 128); // refresh_entropy_probs = 0
  e.write(1, 128); // refresh_last_frame = 1

  // No coef updates.
  for (int t = 0; t < blockTypes; t++) {
    for (int b = 0; b < coefBands; b++) {
      for (int c = 0; c < prevCoefContexts; c++) {
        for (int n = 0; n < entropyNodes; n++) {
          e.write(0, coefUpdateProbs[coefProbIndex(t, b, c, n)]);
        }
      }
    }
  }

  // mb_no_coeff_skip = 1, prob_skip_false = 200
  e.write(1, 128);
  e.writeLiteral(200, 8);

  // prob_intra/last/gf
  e.writeLiteral(probIntra, 8);
  e.writeLiteral(probLast, 8);
  e.writeLiteral(probGf, 8);

  // y_mode_prob update flag = 1
  e.write(1, 128);
  for (final p in updatedYMode) {
    e.writeLiteral(p, 8);
  }
  // uv_mode_prob update flag = 0
  e.write(0, 128);

  // mv prob updates: all flags 0.
  for (int ctx = 0; ctx < 2; ctx++) {
    for (int i = 0; i < mvpCount; i++) {
      e.write(0, mvUpdateProbs[ctx * mvpCount + i]);
    }
  }
  return e.finish();
}

void main() {
  group('parseFrameHeader', () {
    test('keyframe minimal round-trip', () {
      final boolPart = _encodeMinimalKeyframeBoolPart();
      // Reserve some bytes pretending to be the residual partitions.
      final residual = List<int>.filled(8, 0);
      final firstPartSize = boolPart.length;
      final bytes = <int>[
        ..._tag(
          keyFrame: true,
          version: 0,
          showFrame: true,
          firstPartitionSize: firstPartSize,
        ),
        ..._kfBlock(width: 640, hScale: 0, height: 480, vScale: 0),
        ...boolPart,
        ...residual,
      ];

      final h = parseFrameHeader(Uint8List.fromList(bytes));
      expect(h.isKeyFrame, isTrue);
      expect(h.version, equals(0));
      expect(h.showFrame, isTrue);
      expect(h.firstPartitionSize, equals(firstPartSize));
      expect(h.width, equals(640));
      expect(h.height, equals(480));
      expect(h.horizScale, equals(0));
      expect(h.vertScale, equals(0));
      expect(h.colorSpace, equals(0));
      expect(h.clampingType, equals(0));

      expect(h.segmentation.enabled, isFalse);
      expect(h.loopFilter.type, equals(0));
      expect(h.loopFilter.level, equals(20));
      expect(h.loopFilter.sharpness, equals(3));
      expect(h.loopFilter.modeRefDeltaEnabled, isFalse);

      expect(h.log2NumDctPartitions, equals(0));
      expect(h.quantizer.yAcQi, equals(42));
      expect(h.quantizer.y1DcDelta, equals(0));
      expect(h.quantizer.y2DcDelta, equals(0));
      expect(h.quantizer.y2AcDelta, equals(0));
      expect(h.quantizer.uvDcDelta, equals(0));
      expect(h.quantizer.uvAcDelta, equals(0));

      expect(h.refreshEntropyProbs, isTrue);
      expect(h.refreshLastFrame, isTrue);
      expect(h.refreshGoldenFrame, isTrue);
      expect(h.refreshAltrefFrame, isTrue);

      expect(h.mbNoCoeffSkip, isFalse);
      expect(h.probSkipFalse, equals(0));

      // Coef probs untouched -> equal to defaults.
      expect(h.coefProbs, equals(defaultCoefProbs));

      // Residual partitions begin at 3 + 7 + firstPartSize.
      expect(h.residualPartitionsOffset, equals(3 + 7 + firstPartSize));
    });

    test('interframe with updates', () {
      final updatedYMode = <int>[100, 90, 130, 40];
      final boolPart = _encodeInterframeBoolPart(
        probIntra: 60,
        probLast: 100,
        probGf: 145,
        updatedYMode: updatedYMode,
      );
      final firstPartSize = boolPart.length;
      final bytes = <int>[
        ..._tag(
          keyFrame: false,
          version: 1,
          showFrame: true,
          firstPartitionSize: firstPartSize,
        ),
        ...boolPart,
      ];

      final h = parseFrameHeader(Uint8List.fromList(bytes));
      expect(h.isKeyFrame, isFalse);
      expect(h.version, equals(1));
      expect(h.showFrame, isTrue);
      expect(h.loopFilter.type, equals(1));
      expect(h.loopFilter.level, equals(33));
      expect(h.loopFilter.sharpness, equals(2));
      expect(h.log2NumDctPartitions, equals(1));

      expect(h.quantizer.yAcQi, equals(50));
      expect(h.quantizer.y1DcDelta, equals(-3));
      expect(h.quantizer.y2DcDelta, equals(0));

      expect(h.refreshGoldenFrame, isFalse);
      expect(h.refreshAltrefFrame, isTrue);
      expect(h.copyBufferToGf, equals(2));
      expect(h.copyBufferToArf, equals(0)); // not transmitted
      expect(h.signBiasGolden, isTrue);
      expect(h.signBiasAltref, isFalse);

      expect(h.refreshEntropyProbs, isFalse);
      expect(h.refreshLastFrame, isTrue);

      expect(h.mbNoCoeffSkip, isTrue);
      expect(h.probSkipFalse, equals(200));

      expect(h.probIntra, equals(60));
      expect(h.probLast, equals(100));
      expect(h.probGf, equals(145));

      expect(h.yModeProb, equals(updatedYMode));
      expect(h.uvModeProb, equals(defaultUvModeProb));

      // MV context not updated => equals defaults.
      expect(h.mvContext, equals(defaultMvContext));
    });

    test('rejects bad sync code', () {
      final boolPart = _encodeMinimalKeyframeBoolPart();
      final bad = <int>[
        ..._tag(
          keyFrame: true,
          version: 0,
          showFrame: true,
          firstPartitionSize: boolPart.length,
        ),
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // wrong sync
        ...boolPart,
      ];
      expect(() => parseFrameHeader(Uint8List.fromList(bad)),
          throwsFormatException);
    });
  });
}
