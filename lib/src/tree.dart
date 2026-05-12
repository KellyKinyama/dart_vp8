// VP8 boolean-tree decoder and the small set of trees used by mode/MV
// decoding. Direct port of vp8/common/treecoder.* + the tree tables in
// vp8/common/entropymode.c.
//
// A tree is encoded as a flat `List<int>`. Each internal node occupies two
// consecutive entries: `[left, right]`. A nonpositive entry `-leaf` is a
// terminal whose decoded value is `leaf`. A positive entry is the index of
// another internal node (always even). The decoder walks the tree, reading
// one bit at each node with probability `probs[node >> 1]`, until it hits a
// leaf.

import 'bool_decoder.dart';

/// Walk `tree`, reading bits from `bc` using `probs` (indexed by
/// `node >> 1`), starting at the root.
int treeDecode(BoolDecoder bc, List<int> tree, List<int> probs) {
  int i = 0;
  while (true) {
    final int j = i + bc.read(probs[i >> 1]);
    final int t = tree[j];
    if (t <= 0) return -t;
    i = t;
  }
}

// ---------------------------------------------------------------------------
// Tree tables. All values match libvpx 1:1.

/// VP8 16x16 Y modes (intra-only): {DC_PRED, V_PRED, H_PRED, TM_PRED, B_PRED}.
const int dcPredM = 0;
const int vPredM = 1;
const int hPredM = 2;
const int tmPredM = 3;
const int bPredM = 4;

/// vp8_kf_ymode_tree: keyframe Y-mode tree (RFC 6386 §11.2).
const List<int> kfYmodeTree = <int>[
  -bPredM,
  2,
  4,
  6,
  -dcPredM,
  -vPredM,
  -hPredM,
  -tmPredM,
];

/// vp8_ymode_tree: inter-frame Y-mode tree (used when refFrame == INTRA_FRAME).
const List<int> ymodeTree = <int>[
  -dcPredM,
  2,
  4,
  6,
  -vPredM,
  -hPredM,
  -tmPredM,
  -bPredM,
];

/// vp8_uv_mode_tree: UV-mode tree (key or inter).
const List<int> uvModeTree = <int>[
  -dcPredM,
  2,
  -vPredM,
  4,
  -hPredM,
  -tmPredM,
];

/// vp8_bmode_tree: per-4x4 B-mode tree (10 leaves).
/// Matches the names in intra_pred.dart (bDcPred..bHuPred = 0..9).
const List<int> bmodeTree = <int>[
  0, 2, // -B_DC_PRED, 2  (use 0 for leaf B_DC_PRED == -0)
  -1, 4, // -B_TM_PRED
  -2, 6, // -B_VE_PRED
  8, 12,
  -3, 10, // -B_HE_PRED
  -5, -6, // -B_RD_PRED, -B_VR_PRED
  -4, 14, // -B_LD_PRED
  -7, 16, // -B_VL_PRED
  -8, -9, // -B_HD_PRED, -B_HU_PRED
];

/// Segment-ID tree (3 internal nodes, 4 leaves). Index = segment id (0..3).
/// libvpx: vp8_mb_feature_tree.
const List<int> mbFeatureTree = <int>[
  2,
  4,
  -0,
  -1,
  -2,
  -3,
];
