// VP8 dequantization tables and helpers.
//
// Sources:
//   * vp8/common/quant_common.c
//   * vp8/common/blockd.h (Q index range = 128)
//
// `qindexClamp` is libvpx's `if QIndex>127 -> 127; if <0 -> 0` operation
// applied after adding any delta.

import 'dart:typed_data';

/// Number of distinct quantizer indices in the VP8 spec (0..127).
const int qIndexRange = 128;

/// DC quantizer lookup table.
final Uint16List dcQLookup = Uint16List.fromList(<int>[
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  17,
  18,
  19,
  20,
  20,
  21,
  21,
  22,
  22,
  23,
  23,
  24,
  25,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  35,
  36,
  37,
  37,
  38,
  39,
  40,
  41,
  42,
  43,
  44,
  45,
  46,
  46,
  47,
  48,
  49,
  50,
  51,
  52,
  53,
  54,
  55,
  56,
  57,
  58,
  59,
  60,
  61,
  62,
  63,
  64,
  65,
  66,
  67,
  68,
  69,
  70,
  71,
  72,
  73,
  74,
  75,
  76,
  76,
  77,
  78,
  79,
  80,
  81,
  82,
  83,
  84,
  85,
  86,
  87,
  88,
  89,
  91,
  93,
  95,
  96,
  98,
  100,
  101,
  102,
  104,
  106,
  108,
  110,
  112,
  114,
  116,
  118,
  122,
  124,
  126,
  128,
  130,
  132,
  134,
  136,
  138,
  140,
  143,
  145,
  148,
  151,
  154,
  157,
]);

/// AC quantizer lookup table.
final Uint16List acQLookup = Uint16List.fromList(<int>[
  4,
  5,
  6,
  7,
  8,
  9,
  10,
  11,
  12,
  13,
  14,
  15,
  16,
  17,
  18,
  19,
  20,
  21,
  22,
  23,
  24,
  25,
  26,
  27,
  28,
  29,
  30,
  31,
  32,
  33,
  34,
  35,
  36,
  37,
  38,
  39,
  40,
  41,
  42,
  43,
  44,
  45,
  46,
  47,
  48,
  49,
  50,
  51,
  52,
  53,
  54,
  55,
  56,
  57,
  58,
  60,
  62,
  64,
  66,
  68,
  70,
  72,
  74,
  76,
  78,
  80,
  82,
  84,
  86,
  88,
  90,
  92,
  94,
  96,
  98,
  100,
  102,
  104,
  106,
  108,
  110,
  112,
  114,
  116,
  119,
  122,
  125,
  128,
  131,
  134,
  137,
  140,
  143,
  146,
  149,
  152,
  155,
  158,
  161,
  164,
  167,
  170,
  173,
  177,
  181,
  185,
  189,
  193,
  197,
  201,
  205,
  209,
  213,
  217,
  221,
  225,
  229,
  234,
  239,
  245,
  249,
  254,
  259,
  264,
  269,
  274,
  279,
  284,
]);

int _clampQi(int q) {
  if (q < 0) return 0;
  if (q > 127) return 127;
  return q;
}

int yDcQuant(int qi, int delta) => dcQLookup[_clampQi(qi + delta)];
int yAcQuant(int qi) => acQLookup[_clampQi(qi)];

int y2DcQuant(int qi, int delta) => dcQLookup[_clampQi(qi + delta)] * 2;
int y2AcQuant(int qi, int delta) {
  // libvpx: retval = (ac_qlookup[QIndex] * 101581) >> 16, then floor 8.
  final int v = (acQLookup[_clampQi(qi + delta)] * 101581) >> 16;
  return v < 8 ? 8 : v;
}

int uvDcQuant(int qi, int delta) {
  final int v = dcQLookup[_clampQi(qi + delta)];
  return v > 132 ? 132 : v;
}

int uvAcQuant(int qi, int delta) => acQLookup[_clampQi(qi + delta)];

/// Five plane-specific dequant 2-element pairs `(DC, AC)` for a single
/// segment, in libvpx's per-plane convention:
///   index 0 -> Y1 (luma AC plane, DC handled by Y2 when present)
///   index 1 -> Y2 (luma DC plane, 4x4 WHT)
///   index 2 -> UV (shared)
///
/// Each pair has DC at index 0 and AC at index 1; the AC value is
/// replicated for coefficient positions 1..15 by the caller.
class DequantSet {
  DequantSet(this.y1Dc, this.y1Ac, this.y2Dc, this.y2Ac, this.uvDc, this.uvAc);
  final int y1Dc;
  final int y1Ac;
  final int y2Dc;
  final int y2Ac;
  final int uvDc;
  final int uvAc;
}

/// Build the dequant set for the given base quantizer index and the five
/// signed deltas read from the frame header.
DequantSet buildDequant({
  required int qi,
  required int y1DcDelta,
  required int y2DcDelta,
  required int y2AcDelta,
  required int uvDcDelta,
  required int uvAcDelta,
}) {
  return DequantSet(
    yDcQuant(qi, y1DcDelta),
    yAcQuant(qi),
    y2DcQuant(qi, y2DcDelta),
    y2AcQuant(qi, y2AcDelta),
    uvDcQuant(qi, uvDcDelta),
    uvAcQuant(qi, uvAcDelta),
  );
}
