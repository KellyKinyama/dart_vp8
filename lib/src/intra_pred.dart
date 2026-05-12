// VP8 intra prediction.
//
// Verbatim port of:
//   * vp8/common/reconintra.c (16x16 luma, 8x8 chroma -- DC/V/H/TM)
//   * vp8/common/reconintra4x4.c + vpx_dsp/intrapred.c 4x4 predictors:
//     B_DC, B_TM, B_VE, B_HE, B_LD (d45e), B_RD (d135), B_VR (d117),
//     B_VL (d63e), B_HD (d153), B_HU (d207).
//
// All routines operate on row-major Uint8List buffers; strides are in bytes.
// Callers gather the `above` row and `left` column ahead of time (libvpx
// does the same -- it builds a private stack copy on each call).

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// VP8 MB intra modes (Y 16x16 and UV 8x8 share the same numbering).
const int dcPred = 0;
const int vPred = 1;
const int hPred = 2;
const int tmPred = 3;

/// Indicates per-4x4 B-modes follow. Y only; not valid as an 8x8 UV mode.
const int bPred = 4;

// VP8 B (4x4 luma) modes.
const int bDcPred = 0;
const int bTmPred = 1;
const int bVePred = 2;
const int bHePred = 3;
const int bLdPred = 4;
const int bRdPred = 5;
const int bVrPred = 6;
const int bVlPred = 7;
const int bHdPred = 8;
const int bHuPred = 9;

int _clip8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

int _a2(int a, int b) => (a + b + 1) >> 1;
int _a3(int a, int b, int c) => (a + 2 * b + c + 2) >> 2;

// ---------------------------------------------------------------------------
// 16x16 and 8x8 predictors.

void _vPred(
    Uint8List dst, int off, int stride, Uint8List above, int aboveOff, int bs) {
  for (int r = 0; r < bs; r++) {
    final int row = off + r * stride;
    for (int c = 0; c < bs; c++) {
      dst[row + c] = above[aboveOff + c];
    }
  }
}

void _hPred(
    Uint8List dst, int off, int stride, Uint8List left, int leftOff, int bs) {
  for (int r = 0; r < bs; r++) {
    final int row = off + r * stride;
    final int v = left[leftOff + r];
    for (int c = 0; c < bs; c++) {
      dst[row + c] = v;
    }
  }
}

void _tmPred(Uint8List dst, int off, int stride, Uint8List above, int aboveOff,
    Uint8List left, int leftOff, int topLeft, int bs) {
  for (int r = 0; r < bs; r++) {
    final int row = off + r * stride;
    final int l = left[leftOff + r];
    for (int c = 0; c < bs; c++) {
      dst[row + c] = _clip8(l + above[aboveOff + c] - topLeft);
    }
  }
}

void _dcFill(Uint8List dst, int off, int stride, int v, int bs) {
  for (int r = 0; r < bs; r++) {
    final int row = off + r * stride;
    for (int c = 0; c < bs; c++) {
      dst[row + c] = v;
    }
  }
}

void _dcPred(Uint8List dst, int off, int stride, Uint8List above, int aboveOff,
    Uint8List left, int leftOff, bool upAvail, bool leftAvail, int bs) {
  int v;
  if (upAvail && leftAvail) {
    int sum = 0;
    for (int i = 0; i < bs; i++) {
      sum += above[aboveOff + i];
      sum += left[leftOff + i];
    }
    final int count = 2 * bs;
    v = (sum + (count >> 1)) ~/ count;
  } else if (upAvail) {
    int sum = 0;
    for (int i = 0; i < bs; i++) {
      sum += above[aboveOff + i];
    }
    v = (sum + (bs >> 1)) ~/ bs;
  } else if (leftAvail) {
    int sum = 0;
    for (int i = 0; i < bs; i++) {
      sum += left[leftOff + i];
    }
    v = (sum + (bs >> 1)) ~/ bs;
  } else {
    v = 128;
  }
  _dcFill(dst, off, stride, v, bs);
}

void _predictNxN(
  int mode,
  Uint8List dst,
  int dstOff,
  int dstStride,
  Uint8List above,
  int aboveOff,
  Uint8List left,
  int leftOff,
  int topLeft,
  bool upAvail,
  bool leftAvail,
  int bs,
) {
  switch (mode) {
    case dcPred:
      _dcPred(dst, dstOff, dstStride, above, aboveOff, left, leftOff, upAvail,
          leftAvail, bs);
      return;
    case vPred:
      _vPred(dst, dstOff, dstStride, above, aboveOff, bs);
      return;
    case hPred:
      _hPred(dst, dstOff, dstStride, left, leftOff, bs);
      return;
    case tmPred:
      _tmPred(
          dst, dstOff, dstStride, above, aboveOff, left, leftOff, topLeft, bs);
      return;
    default:
      throw ArgumentError('invalid intra mode $mode');
  }
}

/// Predict a 16x16 luma block (`mode` is one of [dcPred], [vPred], [hPred],
/// [tmPred]). When `mode == dcPred`, `upAvail`/`leftAvail` select the DC
/// formula variant per VP8. `topLeft` is used only by [tmPred].
void predict16x16(
  int mode,
  Uint8List dst,
  int dstOff,
  int dstStride,
  Uint8List above,
  int aboveOff,
  Uint8List left,
  int leftOff,
  int topLeft,
  bool upAvail,
  bool leftAvail,
) {
  _predictNxN(mode, dst, dstOff, dstStride, above, aboveOff, left, leftOff,
      topLeft, upAvail, leftAvail, 16);
}

/// Predict an 8x8 chroma (U or V) block. Same arguments as [predict16x16];
/// `bs=8`.
void predict8x8(
  int mode,
  Uint8List dst,
  int dstOff,
  int dstStride,
  Uint8List above,
  int aboveOff,
  Uint8List left,
  int leftOff,
  int topLeft,
  bool upAvail,
  bool leftAvail,
) {
  _predictNxN(mode, dst, dstOff, dstStride, above, aboveOff, left, leftOff,
      topLeft, upAvail, leftAvail, 8);
}

// ---------------------------------------------------------------------------
// 4x4 B-mode predictors.
//
// `above` must contain 8 samples (indices aboveOff .. aboveOff+7).
// `left`  must contain 4 samples (indices leftOff  .. leftOff+3).
// `topLeft` is the pixel just above-left of the 4x4 block.

void _bDc(Uint8List dst, int o, int s, Uint8List above, int ao, Uint8List left,
    int lo) {
  // VP8 B_DC always uses the full average of above[0..3] + left[0..3] + 4.
  final int sum = above[ao] +
      above[ao + 1] +
      above[ao + 2] +
      above[ao + 3] +
      left[lo] +
      left[lo + 1] +
      left[lo + 2] +
      left[lo + 3];
  final int v = (sum + 4) >> 3;
  for (int r = 0; r < 4; r++) {
    final int row = o + r * s;
    dst[row] = v;
    dst[row + 1] = v;
    dst[row + 2] = v;
    dst[row + 3] = v;
  }
}

void _bTm(Uint8List dst, int o, int s, int topLeft, Uint8List above, int ao,
    Uint8List left, int lo) {
  for (int r = 0; r < 4; r++) {
    final int row = o + r * s;
    final int l = left[lo + r];
    for (int c = 0; c < 4; c++) {
      dst[row + c] = _clip8(l + above[ao + c] - topLeft);
    }
  }
}

void _bVe(Uint8List dst, int o, int s, int topLeft, Uint8List above, int ao) {
  final int h = topLeft;
  final int i = above[ao];
  final int j = above[ao + 1];
  final int k = above[ao + 2];
  final int l = above[ao + 3];
  final int m = above[ao + 4];
  final int v0 = _a3(h, i, j);
  final int v1 = _a3(i, j, k);
  final int v2 = _a3(j, k, l);
  final int v3 = _a3(k, l, m);
  for (int r = 0; r < 4; r++) {
    final int row = o + r * s;
    dst[row] = v0;
    dst[row + 1] = v1;
    dst[row + 2] = v2;
    dst[row + 3] = v3;
  }
}

void _bHe(Uint8List dst, int o, int s, int topLeft, Uint8List left, int lo) {
  final int hh = topLeft;
  final int ii = left[lo];
  final int jj = left[lo + 1];
  final int kk = left[lo + 2];
  final int ll = left[lo + 3];
  final int r0 = _a3(hh, ii, jj);
  final int r1 = _a3(ii, jj, kk);
  final int r2 = _a3(jj, kk, ll);
  final int r3 = _a3(kk, ll, ll);
  final int row0 = o;
  final int row1 = o + s;
  final int row2 = o + 2 * s;
  final int row3 = o + 3 * s;
  dst[row0] = dst[row0 + 1] = dst[row0 + 2] = dst[row0 + 3] = r0;
  dst[row1] = dst[row1 + 1] = dst[row1 + 2] = dst[row1 + 3] = r1;
  dst[row2] = dst[row2 + 1] = dst[row2 + 2] = dst[row2 + 3] = r2;
  dst[row3] = dst[row3 + 1] = dst[row3 + 2] = dst[row3 + 3] = r3;
}

// B_LD = vpx_d45e_predictor_4x4_c.
void _bLd(Uint8List dst, int o, int s, Uint8List above, int ao) {
  final int a = above[ao];
  final int b = above[ao + 1];
  final int c = above[ao + 2];
  final int d = above[ao + 3];
  final int e = above[ao + 4];
  final int f = above[ao + 5];
  final int g = above[ao + 6];
  final int h = above[ao + 7];

  // DST(x, y) -> dst[o + x + y*s]
  int p(int x, int y) => o + x + y * s;
  dst[p(0, 0)] = _a3(a, b, c);
  dst[p(1, 0)] = dst[p(0, 1)] = _a3(b, c, d);
  dst[p(2, 0)] = dst[p(1, 1)] = dst[p(0, 2)] = _a3(c, d, e);
  dst[p(3, 0)] = dst[p(2, 1)] = dst[p(1, 2)] = dst[p(0, 3)] = _a3(d, e, f);
  dst[p(3, 1)] = dst[p(2, 2)] = dst[p(1, 3)] = _a3(e, f, g);
  dst[p(3, 2)] = dst[p(2, 3)] = _a3(f, g, h);
  dst[p(3, 3)] = _a3(g, h, h);
}

// B_RD = vpx_d135_predictor_4x4_c.
void _bRd(Uint8List dst, int o, int s, int topLeft, Uint8List above, int ao,
    Uint8List left, int lo) {
  final int i = left[lo];
  final int j = left[lo + 1];
  final int k = left[lo + 2];
  final int l = left[lo + 3];
  final int x = topLeft;
  final int a = above[ao];
  final int b = above[ao + 1];
  final int c = above[ao + 2];
  final int d = above[ao + 3];

  int p(int xc, int yr) => o + xc + yr * s;
  dst[p(0, 3)] = _a3(j, k, l);
  dst[p(1, 3)] = dst[p(0, 2)] = _a3(i, j, k);
  dst[p(2, 3)] = dst[p(1, 2)] = dst[p(0, 1)] = _a3(x, i, j);
  dst[p(3, 3)] = dst[p(2, 2)] = dst[p(1, 1)] = dst[p(0, 0)] = _a3(a, x, i);
  dst[p(3, 2)] = dst[p(2, 1)] = dst[p(1, 0)] = _a3(b, a, x);
  dst[p(3, 1)] = dst[p(2, 0)] = _a3(c, b, a);
  dst[p(3, 0)] = _a3(d, c, b);
}

// B_VR = vpx_d117_predictor_4x4_c.
void _bVr(Uint8List dst, int o, int s, int topLeft, Uint8List above, int ao,
    Uint8List left, int lo) {
  final int i = left[lo];
  final int j = left[lo + 1];
  final int k = left[lo + 2];
  final int x = topLeft;
  final int a = above[ao];
  final int b = above[ao + 1];
  final int c = above[ao + 2];
  final int d = above[ao + 3];

  int p(int xc, int yr) => o + xc + yr * s;
  dst[p(0, 0)] = dst[p(1, 2)] = _a2(x, a);
  dst[p(1, 0)] = dst[p(2, 2)] = _a2(a, b);
  dst[p(2, 0)] = dst[p(3, 2)] = _a2(b, c);
  dst[p(3, 0)] = _a2(c, d);

  dst[p(0, 3)] = _a3(k, j, i);
  dst[p(0, 2)] = _a3(j, i, x);
  dst[p(0, 1)] = dst[p(1, 3)] = _a3(i, x, a);
  dst[p(1, 1)] = dst[p(2, 3)] = _a3(x, a, b);
  dst[p(2, 1)] = dst[p(3, 3)] = _a3(a, b, c);
  dst[p(3, 1)] = _a3(b, c, d);
}

// B_VL = vpx_d63e_predictor_4x4_c.
void _bVl(Uint8List dst, int o, int s, Uint8List above, int ao) {
  final int a = above[ao];
  final int b = above[ao + 1];
  final int c = above[ao + 2];
  final int d = above[ao + 3];
  final int e = above[ao + 4];
  final int f = above[ao + 5];
  final int g = above[ao + 6];
  final int h = above[ao + 7];

  int p(int xc, int yr) => o + xc + yr * s;
  dst[p(0, 0)] = _a2(a, b);
  dst[p(1, 0)] = dst[p(0, 2)] = _a2(b, c);
  dst[p(2, 0)] = dst[p(1, 2)] = _a2(c, d);
  dst[p(3, 0)] = dst[p(2, 2)] = _a2(d, e);
  dst[p(3, 2)] = _a3(e, f, g);

  dst[p(0, 1)] = _a3(a, b, c);
  dst[p(1, 1)] = dst[p(0, 3)] = _a3(b, c, d);
  dst[p(2, 1)] = dst[p(1, 3)] = _a3(c, d, e);
  dst[p(3, 1)] = dst[p(2, 3)] = _a3(d, e, f);
  dst[p(3, 3)] = _a3(f, g, h);
}

// B_HD = vpx_d153_predictor_4x4_c.
void _bHd(Uint8List dst, int o, int s, int topLeft, Uint8List above, int ao,
    Uint8List left, int lo) {
  final int i = left[lo];
  final int j = left[lo + 1];
  final int k = left[lo + 2];
  final int l = left[lo + 3];
  final int x = topLeft;
  final int a = above[ao];
  final int b = above[ao + 1];
  final int c = above[ao + 2];

  int p(int xc, int yr) => o + xc + yr * s;
  dst[p(0, 0)] = dst[p(2, 1)] = _a2(i, x);
  dst[p(0, 1)] = dst[p(2, 2)] = _a2(j, i);
  dst[p(0, 2)] = dst[p(2, 3)] = _a2(k, j);
  dst[p(0, 3)] = _a2(l, k);

  dst[p(3, 0)] = _a3(a, b, c);
  dst[p(2, 0)] = _a3(x, a, b);
  dst[p(1, 0)] = dst[p(3, 1)] = _a3(i, x, a);
  dst[p(1, 1)] = dst[p(3, 2)] = _a3(j, i, x);
  dst[p(1, 2)] = dst[p(3, 3)] = _a3(k, j, i);
  dst[p(1, 3)] = _a3(l, k, j);
}

// B_HU = vpx_d207_predictor_4x4_c.
void _bHu(Uint8List dst, int o, int s, Uint8List left, int lo) {
  final int i = left[lo];
  final int j = left[lo + 1];
  final int k = left[lo + 2];
  final int l = left[lo + 3];

  int p(int xc, int yr) => o + xc + yr * s;
  dst[p(0, 0)] = _a2(i, j);
  dst[p(2, 0)] = dst[p(0, 1)] = _a2(j, k);
  dst[p(2, 1)] = dst[p(0, 2)] = _a2(k, l);
  dst[p(1, 0)] = _a3(i, j, k);
  dst[p(3, 0)] = dst[p(1, 1)] = _a3(j, k, l);
  dst[p(3, 1)] = dst[p(1, 2)] = _a3(k, l, l);
  dst[p(3, 2)] = dst[p(2, 2)] =
      dst[p(0, 3)] = dst[p(1, 3)] = dst[p(2, 3)] = dst[p(3, 3)] = l;
}

/// Predict a 4x4 luma block using one of the 10 B-modes.
///
/// `above` must hold 8 samples at indices `aboveOff..aboveOff+7`. For
/// modes that only consult 4 above samples, the remaining 4 are ignored
/// but caller must still provide a valid backing buffer.
/// `left` must hold 4 samples at indices `leftOff..leftOff+3`.
/// `topLeft` is the pixel at the above-left corner.
void predict4x4(
  int bMode,
  Uint8List dst,
  int dstOff,
  int dstStride,
  int topLeft,
  Uint8List above,
  int aboveOff,
  Uint8List left,
  int leftOff,
) {
  switch (bMode) {
    case bDcPred:
      _bDc(dst, dstOff, dstStride, above, aboveOff, left, leftOff);
      return;
    case bTmPred:
      _bTm(dst, dstOff, dstStride, topLeft, above, aboveOff, left, leftOff);
      return;
    case bVePred:
      _bVe(dst, dstOff, dstStride, topLeft, above, aboveOff);
      return;
    case bHePred:
      _bHe(dst, dstOff, dstStride, topLeft, left, leftOff);
      return;
    case bLdPred:
      _bLd(dst, dstOff, dstStride, above, aboveOff);
      return;
    case bRdPred:
      _bRd(dst, dstOff, dstStride, topLeft, above, aboveOff, left, leftOff);
      return;
    case bVrPred:
      _bVr(dst, dstOff, dstStride, topLeft, above, aboveOff, left, leftOff);
      return;
    case bVlPred:
      _bVl(dst, dstOff, dstStride, above, aboveOff);
      return;
    case bHdPred:
      _bHd(dst, dstOff, dstStride, topLeft, above, aboveOff, left, leftOff);
      return;
    case bHuPred:
      _bHu(dst, dstOff, dstStride, left, leftOff);
      return;
    default:
      throw ArgumentError('invalid 4x4 B-mode $bMode');
  }
}
