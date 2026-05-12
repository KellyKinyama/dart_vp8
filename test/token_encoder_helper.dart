// Test-only token encoder that mirrors lib/src/entropy.dart `_decodeBlockCoeffs`.
// Supports only coefficient values in {-1, 0, +1}, which is enough to
// exercise band/context bookkeeping without recreating libvpx's full
// magnitude-extra-bits machinery.

import 'package:dart_vp8/src/constants/coef_probs.dart';

import 'bool_encoder_helper.dart';

class TokenEncoder {
  TokenEncoder(this.coefProbs);
  final List<int> coefProbs; // Uint8List works too
  final BoolEncoder enc = BoolEncoder();

  int _p(int t, int band, int ctx, int node) =>
      coefProbs[coefProbIndex(t, band, ctx, node)];

  /// Emit a 4x4 block.
  ///
  /// `coeffs` is the natural-order (zigzag-pre-permutation) coefficient
  /// array of length 16. Coefficient at scan position `n` corresponds to
  /// raster position `kZigzag[n]`. Only -1/0/+1 values are supported.
  void encodeBlock({
    required int blockType,
    required int startN,
    required int initialCtx,
    required List<int> coeffs, // natural-scan order, length 16
  }) {
    // Find last non-zero scan position. If none and startN==0 -> EOB before
    // any coeff. (When startN==1, the implicit "block has coeffs" is still
    // signaled at the same first bit; libvpx applies the same EOB-before-
    // any-coeff logic regardless of skipDc.)
    int lastNz = -1;
    for (int i = 15; i >= 0; i--) {
      if (coeffs[i] != 0) {
        lastNz = i;
        break;
      }
    }

    int band = _kBands[startN];
    int ctx = initialCtx;

    if (lastNz < startN) {
      // Block is all-zero from the decoder's perspective (any DC slot
      // skipped is irrelevant). Emit a single "no coeffs" bit.
      enc.write(0, _p(blockType, band, ctx, 0));
      return;
    }
    enc.write(1, _p(blockType, band, ctx, 0));

    int n = startN;
    while (true) {
      n++;
      final int scanPos = n - 1;
      final int v = coeffs[scanPos];
      if (v == 0) {
        enc.write(0, _p(blockType, band, ctx, 1));
        band = _kBands[n];
        ctx = 0;
      } else {
        enc.write(1, _p(blockType, band, ctx, 1));
        final int absV = v.abs();
        if (absV == 1) {
          enc.write(0, _p(blockType, band, ctx, 2));
          band = _kBands[n];
          ctx = 1;
        } else {
          throw UnimplementedError('test encoder only supports |v|<=1');
        }
        // Sign bit: 0 -> positive (matches `bc.read(128) != 0 ? -v : v`).
        enc.write(v < 0 ? 1 : 0, 128);

        if (n == 16) return;
        // Decide EOB based on whether any further nonzero exists.
        bool moreNonZero = false;
        for (int k = scanPos + 1; k < 16; k++) {
          if (coeffs[k] != 0) {
            moreNonZero = true;
            break;
          }
        }
        enc.write(moreNonZero ? 1 : 0, _p(blockType, band, ctx, 0));
        if (!moreNonZero) return;
      }
      if (n == 16) return;
    }
  }
}

// Mirror of `_kBands` in lib/src/entropy.dart.
const List<int> _kBands = <int>[
  0,
  1,
  2,
  3,
  6,
  4,
  5,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  7,
  0,
];
