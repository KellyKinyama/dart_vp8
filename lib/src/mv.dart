// VP8 motion vectors, reference-frame constants, and the trees / tables
// used by inter-MB mode and MV decoding.
//
// Sources:
//   * vp8/common/blockd.h           -> MV_REFERENCE_FRAME, MB_PREDICTION_MODE
//   * vp8/common/entropymode.c      -> vp8_mv_ref_tree, vp8_sub_mv_ref_tree,
//                                       vp8_small_mvtree, vp8_mbsplit_tree
//   * vp8/common/modecont.c         -> vp8_mode_contexts
//   * vp8/common/findnearmv.c       -> mv_bias
//   * vp8/decoder/decodemv.c        -> vp8_sub_mv_ref_prob3
//
// MV values are stored in 1/8-pel units. The decoded MV component is in
// 1/4-pel units; libvpx multiplies by 2 in `read_mv` to land in 1/8 pel.

import 'dart:typed_data';

// ---------- Reference frame ids ------------------------------------------

const int refIntra = 0;
const int refLast = 1;
const int refGolden = 2;
const int refAltref = 3;
const int numRefFrames = 4;

// ---------- MB inter prediction modes ------------------------------------
//
// First five values overlap with the intra modes (see `tree.dart`):
//   dcPredM=0, vPredM=1, hPredM=2, tmPredM=3, bPredM=4.

const int nearestMv = 5;
const int nearMv = 6;
const int zeroMv = 7;
const int newMv = 8;
const int splitMv = 9;

// ---------- Per-4x4 sub-mv ref modes (inside SPLITMV) --------------------

const int left4x4 = 10;
const int above4x4 = 11;
const int zero4x4 = 12;
const int new4x4 = 13;

// ---------- A single motion vector ---------------------------------------

class Mv {
  Mv([this.row = 0, this.col = 0]);

  int row;
  int col;

  int get asInt => ((row & 0xffff) << 16) | (col & 0xffff);
  bool get isZero => row == 0 && col == 0;

  Mv copy() => Mv(row, col);
}

// ---------- Packed-MV helpers --------------------------------------------
//
// `bMvs` in [ModeInfo] stores 16 sub-block MVs as a single Int32List with
// the layout `((row & 0xffff) << 16) | (col & 0xffff)`. Both row and col
// are 16-bit signed values. Dart `int` is 64-bit, so the naive
// `(packed << 16) >> 16` sign-extension trick does NOT work — these
// helpers do the right thing.

int packBMv(int row, int col) => ((row & 0xffff) << 16) | (col & 0xffff);

int unpackBMvRow(int packed) {
  final int hi = (packed >> 16) & 0xffff;
  return hi >= 0x8000 ? hi - 0x10000 : hi;
}

int unpackBMvCol(int packed) {
  final int lo = packed & 0xffff;
  return lo >= 0x8000 ? lo - 0x10000 : lo;
}

// ---------- Trees --------------------------------------------------------

/// vp8_mv_ref_tree: chooses among ZEROMV/NEARESTMV/NEARMV/NEWMV/SPLITMV.
const List<int> vp8MvRefTree = <int>[
  -zeroMv,
  2,
  -nearestMv,
  4,
  -nearMv,
  6,
  -newMv,
  -splitMv,
];

/// vp8_sub_mv_ref_tree: per-block within SPLITMV.
const List<int> vp8SubMvRefTree = <int>[
  -left4x4,
  2,
  -above4x4,
  4,
  -zero4x4,
  -new4x4,
];

/// vp8_small_mvtree: 14 entries, leaves are signed magnitudes 0..7.
const List<int> vp8SmallMvTree = <int>[
  2,
  8,
  4,
  6,
  -0,
  -1,
  -2,
  -3,
  10,
  12,
  -4,
  -5,
  -6,
  -7,
];

/// vp8_mbsplit_tree: 4x4=0, 8x8=1, 8x16=2, 16x8=3 (encoded order).
/// Indices match vp8_mbsplit_offset rows below.
const List<int> vp8MbSplitTree = <int>[
  -3,
  2,
  -2,
  4,
  -0,
  -1,
];

// ---------- MV context layout constants (match entropymv.h) --------------

const int mvpIsShort = 0;
const int mvpSign = 1;
const int mvpShort = 2; // 7 short-tree probs at [2..8]
const int mvpBits = 9; // 10 long-magnitude bit probs at [9..18]
const int mvnumShort = 8;
const int mvlongWidth = 10;

// ---------- Mode contexts (6x4) ------------------------------------------

const List<List<int>> vp8ModeContexts = <List<int>>[
  <int>[7, 1, 1, 143],
  <int>[14, 18, 14, 107],
  <int>[135, 64, 57, 68],
  <int>[60, 56, 128, 65],
  <int>[159, 134, 128, 34],
  <int>[234, 188, 128, 28],
];

// ---------- Sub-MV ref probability tables --------------------------------

/// vp8_sub_mv_ref_prob3: indexed by (aez<<2)|(lez<<1)|lea, three probs.
const List<List<int>> vp8SubMvRefProb3 = <List<int>>[
  <int>[147, 136, 18],
  <int>[223, 1, 34],
  <int>[106, 145, 1],
  <int>[208, 1, 1],
  <int>[179, 121, 1],
  <int>[223, 1, 34],
  <int>[179, 121, 1],
  <int>[208, 1, 1],
];

// ---------- MB split tables ----------------------------------------------

/// First block index in subset j for split configuration s.
const List<List<int>> vp8MbSplitOffset = <List<int>>[
  // s=0: 16x8 -> two halves at rows 0 and 8 (block raster)
  <int>[0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  // s=1: 8x16 -> two halves at cols 0 and 2
  <int>[0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  // s=2: 8x8 -> four 8x8 blocks
  <int>[0, 2, 8, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  // s=3: 4x4 -> all 16 4x4 blocks
  <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
];

/// Number of 4x4 sub-blocks per subset in split config s.
const List<int> vp8MbSplitCount = <int>[2, 2, 4, 16];

/// Fill counts for split configs.
const List<int> mbsplitFillCount = <int>[8, 8, 4, 1];

/// Per-subset block raster expansions (matches vp8/decoder/decodemv.c).
const List<List<int>> mbsplitFillOffset = <List<int>>[
  <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  <int>[0, 1, 4, 5, 8, 9, 12, 13, 2, 3, 6, 7, 10, 11, 14, 15],
  <int>[0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15],
  <int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
];

// ---------- MV clamping margins ------------------------------------------

/// In 1/8-pel units. `mb_to_*_edge` in libvpx is in 1/8-pel units; margins
/// here add 16 pixels of slack on either side (matching `LEFT_TOP_MARGIN`
/// and `RIGHT_BOTTOM_MARGIN` in `vp8/decoder/decodemv.c`).
const int mvMarginEdge = 16 * 8; // 128

/// Clamp a single MV to the inclusive 1/8-pel `mb_to_*_edge` bounds.
void clampMv2(
  Mv mv,
  int mbToLeftEdge,
  int mbToRightEdge,
  int mbToTopEdge,
  int mbToBottomEdge,
) {
  if (mv.col < mbToLeftEdge) {
    mv.col = mbToLeftEdge;
  } else if (mv.col > mbToRightEdge) {
    mv.col = mbToRightEdge;
  }
  if (mv.row < mbToTopEdge) {
    mv.row = mbToTopEdge;
  } else if (mv.row > mbToBottomEdge) {
    mv.row = mbToBottomEdge;
  }
}

/// Bias a candidate MV's sign by comparing the candidate ref's sign-bias
/// to the current frame's ref sign-bias. Direct port of `mv_bias` (a
/// macro in libvpx's findnearmv.h).
void mvBias(
  bool candidateSignBias,
  bool currentSignBias,
  Mv mv,
) {
  if (candidateSignBias != currentSignBias) {
    mv.row = -mv.row;
    mv.col = -mv.col;
  }
}

/// Round-towards-zero divide-by-8 used by libvpx when collapsing four 4x4
/// luma MVs to a single 8x8 chroma MV. `temp` is the *sum* of the four
/// luma MV components; result = (temp + sign(temp)*4) / 8.
int chromaMvFromLumaSum(int sum) {
  int t = sum;
  if (t < 0) {
    t -= 4;
  } else {
    t += 4;
  }
  // Dart integer division truncates toward zero, matching C's `/`.
  return t ~/ 8;
}

/// Convenience: pack a (row,col) pair the way `Mv` would store internally,
/// useful when bulk-zeroing Int32Lists.
Int32List newBMvList() => Int32List(16);
