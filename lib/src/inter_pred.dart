// VP8 inter prediction: 6-tap subpel filter and 2-tap bilinear filter.
//
// Verbatim port of vp8/common/filter.c. Supports the four block sizes the
// VP8 decoder needs: 4x4, 8x4, 8x8, 16x16.
//
// Filter math (per libvpx):
//   * 6-tap, weights sum to 128 (`VP8_FILTER_WEIGHT`), result `>> 7`
//     (`VP8_FILTER_SHIFT`), with `+64` rounding before the shift.
//   * Bilinear, two taps sum to 128 likewise.
//   * Both filters run as separable 2-D (horizontal first into an int temp,
//     then vertical to byte output, clamped 0..255).
//
// Sample addressing matches libvpx: callers pass a `src` buffer and an
// `srcOff` pointing at the top-left output pixel position. The filter
// reads 2 samples above / 2 to the left and 3 samples below / 3 to the
// right for the 6-tap variant. The caller is responsible for providing
// a backing buffer with enough surrounding context (libvpx does the same).

import 'dart:typed_data';

/// Bilinear filter taps (8 sub-pel positions, 2 taps).
const List<List<int>> bilinearFilters = [
  [128, 0],
  [112, 16],
  [96, 32],
  [80, 48],
  [64, 64],
  [48, 80],
  [32, 96],
  [16, 112],
];

/// VP8 6-tap sub-pel filters (8 positions x 6 taps).
const List<List<int>> subPelFilters = [
  [0, 0, 128, 0, 0, 0],
  [0, -6, 123, 12, -1, 0],
  [2, -11, 108, 36, -8, 1],
  [0, -9, 93, 50, -6, 0],
  [3, -16, 77, 77, -16, 3],
  [0, -6, 50, 93, -9, 0],
  [1, -8, 36, 108, -11, 2],
  [0, -1, 12, 123, -6, 0],
];

const int _filterWeight = 128;
const int _filterShift = 7;
const int _filterRound = _filterWeight ~/ 2; // 64

int _clip8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

// 6-tap horizontal pass: reads src[-2..3] along a step axis.
// `stepIsRow == true` means pixel_step = `srcStride` (vertical filter
// reused as a "horizontal" pass via swapped step); for the standard
// sixtap_predict, the first pass has pixel_step=1 (horizontal).
//
// SIMD note: an Float32x4 4-wide variant of this pass was prototyped but
// proved *slower* than the scalar form in Dart AOT — each
// `Float32x4(d0, d1, d2, d3)` constructed from gathered byte→double
// conversions allocates an unboxed-but-unhoistable temporary that the
// AOT pipeline does not eliminate, and the int→double→int round-trip on
// every lane defeats the saved multiplies. Keep this loop scalar; it
// compiles to a tight unboxed-int inner body and is hot enough that any
// regression dominates total decode time. (See `inverseWalsh4x4` for the
// path where SIMD does pay off: pure 4-wide additive butterfly on
// Int32x4 with no per-pixel gather.)
void _sixtapFirstPass({
  required Uint8List src,
  required int srcOff,
  required int srcStride,
  required int pixelStep,
  required int outputHeight,
  required int outputWidth,
  required List<int> filter,
  required Int32List out,
}) {
  final int f0 = filter[0];
  final int f1 = filter[1];
  final int f2 = filter[2];
  final int f3 = filter[3];
  final int f4 = filter[4];
  final int f5 = filter[5];
  int sp = srcOff;
  int op = 0;
  for (int i = 0; i < outputHeight; i++) {
    for (int j = 0; j < outputWidth; j++) {
      int t = src[sp - 2 * pixelStep] * f0 +
          src[sp - 1 * pixelStep] * f1 +
          src[sp] * f2 +
          src[sp + pixelStep] * f3 +
          src[sp + 2 * pixelStep] * f4 +
          src[sp + 3 * pixelStep] * f5 +
          _filterRound;
      t = t >> _filterShift;
      out[op + j] = _clip8(t);
      sp++;
    }
    sp += srcStride - outputWidth;
    op += outputWidth;
  }
}

// 6-tap vertical pass. Reads `src[-2..3] * pixelStep` along the step axis,
// then writes clamped byte output. `srcStride` is the temp-buffer stride
// (per libvpx this equals `outputWidth` when wiring the two passes).
// See `_sixtapFirstPass` for the SIMD note.
void _sixtapSecondPass({
  required Int32List src,
  required int srcOff,
  required int srcStride,
  required int pixelStep,
  required int outputHeight,
  required int outputWidth,
  required List<int> filter,
  required Uint8List dst,
  required int dstOff,
  required int dstStride,
}) {
  final int f0 = filter[0];
  final int f1 = filter[1];
  final int f2 = filter[2];
  final int f3 = filter[3];
  final int f4 = filter[4];
  final int f5 = filter[5];
  int sp = srcOff;
  int dp = dstOff;
  for (int i = 0; i < outputHeight; i++) {
    for (int j = 0; j < outputWidth; j++) {
      int t = src[sp - 2 * pixelStep] * f0 +
          src[sp - 1 * pixelStep] * f1 +
          src[sp] * f2 +
          src[sp + pixelStep] * f3 +
          src[sp + 2 * pixelStep] * f4 +
          src[sp + 3 * pixelStep] * f5 +
          _filterRound;
      t = t >> _filterShift;
      dst[dp + j] = _clip8(t);
      sp++;
    }
    sp += srcStride - outputWidth;
    dp += dstStride;
  }
}

void _sixtapPredict({
  required int width,
  required int height,
  required Uint8List src,
  required int srcOff,
  required int srcStride,
  required int xoffset,
  required int yoffset,
  required Uint8List dst,
  required int dstOff,
  required int dstStride,
}) {
  final List<int> hFilter = subPelFilters[xoffset];
  final List<int> vFilter = subPelFilters[yoffset];

  // Horizontal pass: (height + 5) rows x width cols. Start 2 rows above.
  final int firstRows = height + 5;
  final Int32List tmp = Int32List(firstRows * width);
  _sixtapFirstPass(
    src: src,
    srcOff: srcOff - 2 * srcStride,
    srcStride: srcStride,
    pixelStep: 1,
    outputHeight: firstRows,
    outputWidth: width,
    filter: hFilter,
    out: tmp,
  );

  // Vertical pass: start at row 2 of the temp.
  _sixtapSecondPass(
    src: tmp,
    srcOff: 2 * width,
    srcStride: width,
    pixelStep: width,
    outputHeight: height,
    outputWidth: width,
    filter: vFilter,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

/// VP8 6-tap subpel predict for a 4x4 block. `xoffset`/`yoffset` are 0..7.
void sixtapPredict4x4(Uint8List src, int srcOff, int srcStride, int xoffset,
    int yoffset, Uint8List dst, int dstOff, int dstStride) {
  _sixtapPredict(
    width: 4,
    height: 4,
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    xoffset: xoffset,
    yoffset: yoffset,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

/// VP8 6-tap subpel predict for an 8x4 block.
void sixtapPredict8x4(Uint8List src, int srcOff, int srcStride, int xoffset,
    int yoffset, Uint8List dst, int dstOff, int dstStride) {
  _sixtapPredict(
    width: 8,
    height: 4,
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    xoffset: xoffset,
    yoffset: yoffset,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

/// VP8 6-tap subpel predict for an 8x8 block.
void sixtapPredict8x8(Uint8List src, int srcOff, int srcStride, int xoffset,
    int yoffset, Uint8List dst, int dstOff, int dstStride) {
  _sixtapPredict(
    width: 8,
    height: 8,
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    xoffset: xoffset,
    yoffset: yoffset,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

/// VP8 6-tap subpel predict for a 16x16 block.
void sixtapPredict16x16(Uint8List src, int srcOff, int srcStride, int xoffset,
    int yoffset, Uint8List dst, int dstOff, int dstStride) {
  _sixtapPredict(
    width: 16,
    height: 16,
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    xoffset: xoffset,
    yoffset: yoffset,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

// ---------------------------------------------------------------------------
// Bilinear (2-tap) filter.
//
// See the SIMD note on `_sixtapFirstPass`: the same regression applies here
// — Dart AOT does not eliminate the per-iteration `Float32x4(...)` gather,
// so the scalar form (which JIT/AOT compiles to a tight unboxed-int inner
// body) is faster in practice.

void _bilinearFirstPass({
  required Uint8List src,
  required int srcOff,
  required int srcStride,
  required int height,
  required int width,
  required List<int> filter,
  required Uint16List out,
}) {
  final int f0 = filter[0];
  final int f1 = filter[1];
  int sp = srcOff;
  int op = 0;
  for (int i = 0; i < height; i++) {
    for (int j = 0; j < width; j++) {
      final int t =
          (src[sp] * f0 + src[sp + 1] * f1 + _filterRound) >> _filterShift;
      out[op + j] = t;
      sp++;
    }
    sp += srcStride - width;
    op += width;
  }
}

void _bilinearSecondPass({
  required Uint16List src,
  required int srcOff,
  required int height,
  required int width,
  required List<int> filter,
  required Uint8List dst,
  required int dstOff,
  required int dstStride,
}) {
  final int f0 = filter[0];
  final int f1 = filter[1];
  int sp = srcOff;
  int dp = dstOff;
  for (int i = 0; i < height; i++) {
    for (int j = 0; j < width; j++) {
      final int t =
          (src[sp] * f0 + src[sp + width] * f1 + _filterRound) >> _filterShift;
      dst[dp + j] = t;
      sp++;
    }
    dp += dstStride;
  }
}

void _bilinearPredict({
  required int width,
  required int height,
  required Uint8List src,
  required int srcOff,
  required int srcStride,
  required int xoffset,
  required int yoffset,
  required Uint8List dst,
  required int dstOff,
  required int dstStride,
}) {
  final List<int> hFilter = bilinearFilters[xoffset];
  final List<int> vFilter = bilinearFilters[yoffset];
  final Uint16List tmp = Uint16List((height + 1) * width);

  _bilinearFirstPass(
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    height: height + 1,
    width: width,
    filter: hFilter,
    out: tmp,
  );
  _bilinearSecondPass(
    src: tmp,
    srcOff: 0,
    height: height,
    width: width,
    filter: vFilter,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

/// VP8 bilinear predict for a 4x4 block.
void bilinearPredict4x4(Uint8List src, int srcOff, int srcStride, int xoffset,
    int yoffset, Uint8List dst, int dstOff, int dstStride) {
  _bilinearPredict(
    width: 4,
    height: 4,
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    xoffset: xoffset,
    yoffset: yoffset,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

/// VP8 bilinear predict for an 8x4 block.
void bilinearPredict8x4(Uint8List src, int srcOff, int srcStride, int xoffset,
    int yoffset, Uint8List dst, int dstOff, int dstStride) {
  _bilinearPredict(
    width: 8,
    height: 4,
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    xoffset: xoffset,
    yoffset: yoffset,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

/// VP8 bilinear predict for an 8x8 block.
void bilinearPredict8x8(Uint8List src, int srcOff, int srcStride, int xoffset,
    int yoffset, Uint8List dst, int dstOff, int dstStride) {
  _bilinearPredict(
    width: 8,
    height: 8,
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    xoffset: xoffset,
    yoffset: yoffset,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}

/// VP8 bilinear predict for a 16x16 block.
void bilinearPredict16x16(Uint8List src, int srcOff, int srcStride, int xoffset,
    int yoffset, Uint8List dst, int dstOff, int dstStride) {
  _bilinearPredict(
    width: 16,
    height: 16,
    src: src,
    srcOff: srcOff,
    srcStride: srcStride,
    xoffset: xoffset,
    yoffset: yoffset,
    dst: dst,
    dstOff: dstOff,
    dstStride: dstStride,
  );
}
