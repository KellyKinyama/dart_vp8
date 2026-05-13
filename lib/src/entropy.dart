// VP8 DCT-coefficient (token) decoding.
//
// Verbatim port of vp8/decoder/detokenize.c:
//   * GetCoeffs        -> [_decodeBlockCoeffs]
//   * vp8_decode_mb_tokens -> [decodeMbTokens]
//
// VP8 organizes a macroblock as 25 4x4 blocks of 16 coefficients each:
//   blocks 0..15  -> Y (raster order)
//   blocks 16..19 -> U
//   blocks 20..23 -> V
//   block 24      -> Y2 (the 4x4 of DC coefficients, present when !is4x4)
//
// All coefficients land in a flat Int16List of length 400 (= 25 * 16).
//
// Each macroblock carries 9 "entropy context" entries above and 9 to the
// left (planes Y[4] + U[2] + V[2] + Y2[1]); they record whether the most
// recently decoded block on each frontier had any nonzero coefficient.

import 'dart:typed_data';

import 'bool_decoder.dart';
import 'constants/coef_probs.dart';

/// DEBUG: when true, [decodeMbTokens] prints per-block context/state.
bool debugTraceTokens = false;

/// Coefficient band of zigzag position n (0..15) plus a sentinel at 16.
/// Matches libvpx's `kBands` in detokenize.c.
const List<int> _kBands = <int>[
  0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7,
  0, // sentinel
];

/// Zigzag scan order: natural position -> raster position within a 4x4 block.
const List<int> kZigzag = <int>[
  0,
  1,
  4,
  8,
  5,
  2,
  3,
  6,
  9,
  12,
  13,
  10,
  7,
  11,
  14,
  15,
];

// Extra-bit probabilities for DCT_VAL_CATEGORY3..6, terminator-style arrays.
const List<int> _kCat3 = <int>[173, 148, 140];
const List<int> _kCat4 = <int>[176, 155, 140, 135];
const List<int> _kCat5 = <int>[180, 157, 141, 134, 130];
const List<int> _kCat6 = <int>[
  254,
  254,
  243,
  230,
  196,
  177,
  153,
  140,
  133,
  130,
  129
];
const List<List<int>> _kCat3456 = <List<int>>[_kCat3, _kCat4, _kCat5, _kCat6];

/// Number of coefficients per block.
const int blockSize = 16;

/// Number of 4x4 blocks per macroblock (Y + U + V + Y2).
const int blocksPerMb = 25;

/// Per-plane entropy context. 9 entries above and 9 to the left:
///   [0..3] Y, [4..5] U, [6..7] V, [8] Y2.
/// Each entry is 0 or 1 (nonzero indicator).
class EntropyContext {
  final Uint8List above = Uint8List(9);
  final Uint8List left = Uint8List(9);

  void resetAll() {
    for (int i = 0; i < 9; i++) {
      above[i] = 0;
      left[i] = 0;
    }
  }
}

/// Width-1 row of macroblock above-contexts.
class AboveContextRow {
  AboveContextRow(int mbCols) : _data = Uint8List(mbCols * 9);
  final Uint8List _data;

  Uint8List sliceFor(int mbX) =>
      Uint8List.sublistView(_data, mbX * 9, mbX * 9 + 9);
}

/// Decode coefficients for one 4x4 block. Returns the position of the last
/// non-zero coefficient plus one (0 if the block is entirely zero).
///
/// * `probs` indexes into the flat coef-prob table; `blockType` selects
///   the outer dimension.
/// * `startN` is 0 for blocks with their own DC, or 1 for the Y-AC blocks
///   when Y2 is present (skip_dc in libvpx).
/// * `ctx` is the running 3-valued context (above+left in {0,1,2}).
/// * `out` receives coefficients at zigzag-mapped raster positions.
int _decodeBlockCoeffs(
  BoolDecoder bc,
  Uint8List probs,
  int blockType,
  int startN,
  int ctx,
  Int16List out,
  int outOffset,
) {
  // p(band, ctx, node) = probs[coefProbIndex(blockType, band, ctx, node)].
  int p(int band, int c, int node) =>
      probs[coefProbIndex(blockType, band, c, node)];

  int n = startN;
  // Initial "any-coeff" bit acts like a CBP flag for the block.
  if (bc.read(p(_kBands[n], ctx, 0)) == 0) {
    return 0;
  }

  // Local mutable context for the running probability slot.
  int band = _kBands[n];
  int curCtx = ctx;

  while (true) {
    n++;
    if (bc.read(p(band, curCtx, 1)) == 0) {
      // Zero coefficient: stay in loop, next prob row uses ctx=0
      // and the new band derived from incremented n.
      band = _kBands[n];
      curCtx = 0;
    } else {
      // Non-zero coefficient.
      int v;
      if (bc.read(p(band, curCtx, 2)) == 0) {
        v = 1;
        band = _kBands[n];
        curCtx = 1;
      } else {
        if (bc.read(p(band, curCtx, 3)) == 0) {
          if (bc.read(p(band, curCtx, 4)) == 0) {
            v = 2;
          } else {
            v = 3 + bc.read(p(band, curCtx, 5));
          }
        } else {
          if (bc.read(p(band, curCtx, 6)) == 0) {
            if (bc.read(p(band, curCtx, 7)) == 0) {
              v = 5 + bc.read(159);
            } else {
              v = 7 + 2 * bc.read(165);
              v += bc.read(145);
            }
          } else {
            final int bit1 = bc.read(p(band, curCtx, 8));
            final int bit0 = bc.read(p(band, curCtx, 9 + bit1));
            final int cat = 2 * bit1 + bit0;
            final List<int> tab = _kCat3456[cat];
            v = 0;
            for (final t in tab) {
              v += v + bc.read(t);
            }
            v += 3 + (8 << cat);
          }
        }
        band = _kBands[n];
        curCtx = 2;
      }

      // Sign bit.
      final int signed = bc.read(128) != 0 ? -v : v;
      out[outOffset + kZigzag[n - 1]] = signed;

      // EOB check (except after position 16).
      if (n == 16) return 16;
      if (bc.read(p(band, curCtx, 0)) == 0) return n;
    }
    if (n == 16) return 16;
  }
}

/// Decode all coefficients for a single macroblock. The full 25-block coeff
/// buffer is written into `qcoeff`; `eobs` receives the EOB index of each
/// block (0..16, plus the Y2 block stored at index 24 when applicable).
///
/// `is4x4` is true for an intra macroblock that uses 4x4 luma prediction
/// (B_PRED); in that case there is no Y2 block.
///
/// Returns the total number of decoded non-zero positions (eobtotal in
/// libvpx); useful as a "skip" indicator.
int decodeMbTokens({
  required BoolDecoder bc,
  required Uint8List coefProbs,
  required bool is4x4,
  required EntropyContext context,
  required Int16List qcoeff,
  required Uint8List eobs,
}) {
  final Uint8List above = context.above;
  final Uint8List left = context.left;
  int eobTotal = 0;
  int skipDc = 0;
  int yBlockType;

  if (!is4x4) {
    // Decode Y2 first (block 24), block type 1, start at n=0.
    final int ctx = above[8] + left[8];
    final int nz = _decodeBlockCoeffs(
      bc,
      coefProbs,
      1,
      0,
      ctx,
      qcoeff,
      24 * 16,
    );
    final int flag = nz > 0 ? 1 : 0;
    above[8] = flag;
    left[8] = flag;
    eobs[24] = nz;
    eobTotal += nz - 16;

    yBlockType = 0; // Y AC plane
    skipDc = 1;
  } else {
    yBlockType = 3; // Y with DC
    eobs[24] = 0;
  }

  // 16 luma 4x4 blocks in raster order.
  for (int i = 0; i < 16; i++) {
    final int aIdx = i & 3;
    final int lIdx = (i & 0xc) >> 2;
    final int ctx = above[aIdx] + left[lIdx];
    if (debugTraceTokens) {
      print(
          '  Y$i ctx=$ctx (above[$aIdx]=${above[aIdx]} left[$lIdx]=${left[lIdx]}) bd=${bc.debugSnapshot()} prob[3][0][$ctx][0]=${coefProbs[coefProbIndex(3, 0, ctx, 0)]}');
    }
    final int nz = _decodeBlockCoeffs(
      bc,
      coefProbs,
      yBlockType,
      skipDc,
      ctx,
      qcoeff,
      i * 16,
    );
    final int flag = nz > 0 ? 1 : 0;
    above[aIdx] = flag;
    left[lIdx] = flag;
    final int eob = nz + skipDc;
    eobs[i] = eob;
    eobTotal += eob;
  }

  // 8 chroma 4x4 blocks (4 U then 4 V). Above/left context entries 4..7.
  for (int i = 16; i < 24; i++) {
    final int aBase = 4 + ((i > 19) ? 2 : 0);
    final int lBase = 4 + ((i > 19) ? 2 : 0);
    final int aIdx = aBase + (i & 1);
    final int lIdx = lBase + (((i & 3) > 1) ? 1 : 0);
    final int ctx = above[aIdx] + left[lIdx];
    final int nz = _decodeBlockCoeffs(
      bc,
      coefProbs,
      2,
      0,
      ctx,
      qcoeff,
      i * 16,
    );
    final int flag = nz > 0 ? 1 : 0;
    above[aIdx] = flag;
    left[lIdx] = flag;
    eobs[i] = nz;
    eobTotal += nz;
  }

  return eobTotal;
}
