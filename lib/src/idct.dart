// VP8 4x4 inverse DCT and 4x4 inverse Walsh-Hadamard transform.
//
// Verbatim port of:
//   * vp8/common/idctllm.c (vp8_short_idct4x4llm_c, vp8_dc_only_idct_add_c,
//     vp8_short_inv_walsh4x4_c, vp8_short_inv_walsh4x4_1_c)
//
// Coefficient layout is row-major: index `r*4+c`.

import 'dart:typed_data';

const int _cospi8sqrt2minus1 = 20091;
const int _sinpi8sqrt2 = 35468;

/// 4x4 inverse DCT followed by clamped add to `pred`, writing into `dst`.
///
/// `input` is 16 dequantized coefficients (row-major). `pred` and `dst`
/// can be the same buffer. Strides are in bytes (i.e. one row).
void idct4x4Add(
  Int16List input,
  int inputOffset,
  Uint8List pred,
  int predOffset,
  int predStride,
  Uint8List dst,
  int dstOffset,
  int dstStride,
) {
  // libvpx's idctllm.c uses a `short output[16]` temp; the second 1-D
  // transform reads from output and writes back into output in-place.
  final Int16List tmp = Int16List(16);

  // Pass 1: column-wise transform. Per libvpx, ip starts at input + 0 and
  // is incremented by 1 each iteration; ip[0], ip[4], ip[8], ip[12] are
  // the four elements of column `i`. Output is written at op[0], op[4],
  // op[8], op[12].
  for (int i = 0; i < 4; i++) {
    final int v0 = input[inputOffset + i];
    final int v4 = input[inputOffset + i + 4];
    final int v8 = input[inputOffset + i + 8];
    final int v12 = input[inputOffset + i + 12];

    final int a1 = v0 + v8;
    final int b1 = v0 - v8;

    int temp1 = (v4 * _sinpi8sqrt2) >> 16;
    int temp2 = v12 + ((v12 * _cospi8sqrt2minus1) >> 16);
    final int c1 = temp1 - temp2;

    temp1 = v4 + ((v4 * _cospi8sqrt2minus1) >> 16);
    temp2 = (v12 * _sinpi8sqrt2) >> 16;
    final int d1 = temp1 + temp2;

    tmp[i + 0] = a1 + d1;
    tmp[i + 12] = a1 - d1;
    tmp[i + 4] = b1 + c1;
    tmp[i + 8] = b1 - c1;
  }

  // Pass 2: row-wise transform. Reads row `i`, writes back same row.
  for (int i = 0; i < 4; i++) {
    final int row = i * 4;
    final int v0 = tmp[row + 0];
    final int v1 = tmp[row + 1];
    final int v2 = tmp[row + 2];
    final int v3 = tmp[row + 3];

    final int a1 = v0 + v2;
    final int b1 = v0 - v2;

    int temp1 = (v1 * _sinpi8sqrt2) >> 16;
    int temp2 = v3 + ((v3 * _cospi8sqrt2minus1) >> 16);
    final int c1 = temp1 - temp2;

    temp1 = v1 + ((v1 * _cospi8sqrt2minus1) >> 16);
    temp2 = (v3 * _sinpi8sqrt2) >> 16;
    final int d1 = temp1 + temp2;

    tmp[row + 0] = (a1 + d1 + 4) >> 3;
    tmp[row + 3] = (a1 - d1 + 4) >> 3;
    tmp[row + 1] = (b1 + c1 + 4) >> 3;
    tmp[row + 2] = (b1 - c1 + 4) >> 3;
  }

  for (int r = 0; r < 4; r++) {
    for (int c = 0; c < 4; c++) {
      int v = tmp[r * 4 + c] + pred[predOffset + r * predStride + c];
      if (v < 0) v = 0;
      if (v > 255) v = 255;
      dst[dstOffset + r * dstStride + c] = v;
    }
  }
}

/// DC-only fast path: equivalent to `idct4x4Add` when only coefficient[0]
/// is non-zero.
void dcOnlyIdct4x4Add(
  int inputDc,
  Uint8List pred,
  int predOffset,
  int predStride,
  Uint8List dst,
  int dstOffset,
  int dstStride,
) {
  final int a1 = (inputDc + 4) >> 3;
  for (int r = 0; r < 4; r++) {
    for (int c = 0; c < 4; c++) {
      int v = a1 + pred[predOffset + r * predStride + c];
      if (v < 0) v = 0;
      if (v > 255) v = 255;
      dst[dstOffset + r * dstStride + c] = v;
    }
  }
}

/// Inverse Walsh-Hadamard 4x4. Reads 16 inputs and writes 16 outputs at
/// `mbDqcoeff[i*16]` (i.e. the DC slot of each of 16 4x4 luma blocks).
void inverseWalsh4x4(
  Int16List input,
  int inputOffset,
  Int16List mbDqcoeff,
  int mbDqcoeffOffset,
) {
  final Int16List output = Int16List(16);

  // Pass 1: column.
  for (int i = 0; i < 4; i++) {
    final int v0 = input[inputOffset + i + 0];
    final int v4 = input[inputOffset + i + 4];
    final int v8 = input[inputOffset + i + 8];
    final int v12 = input[inputOffset + i + 12];

    final int a1 = v0 + v12;
    final int b1 = v4 + v8;
    final int c1 = v4 - v8;
    final int d1 = v0 - v12;

    output[i + 0] = a1 + b1;
    output[i + 4] = c1 + d1;
    output[i + 8] = a1 - b1;
    output[i + 12] = d1 - c1;
  }

  // Pass 2: row, in place.
  for (int i = 0; i < 4; i++) {
    final int row = i * 4;
    final int v0 = output[row + 0];
    final int v1 = output[row + 1];
    final int v2 = output[row + 2];
    final int v3 = output[row + 3];

    final int a1 = v0 + v3;
    final int b1 = v1 + v2;
    final int c1 = v1 - v2;
    final int d1 = v0 - v3;

    final int a2 = a1 + b1;
    final int b2 = c1 + d1;
    final int c2 = a1 - b1;
    final int d2 = d1 - c1;

    output[row + 0] = (a2 + 3) >> 3;
    output[row + 1] = (b2 + 3) >> 3;
    output[row + 2] = (c2 + 3) >> 3;
    output[row + 3] = (d2 + 3) >> 3;
  }

  // Scatter to the 16 luma 4x4 blocks' DC slots.
  for (int i = 0; i < 16; i++) {
    mbDqcoeff[mbDqcoeffOffset + i * 16] = output[i];
  }
}

/// DC-only IWHT fast path. Writes `((input[0] + 3) >> 3)` to every DC slot.
void inverseWalsh4x4Dc(
  int inputDc,
  Int16List mbDqcoeff,
  int mbDqcoeffOffset,
) {
  final int a1 = (inputDc + 3) >> 3;
  for (int i = 0; i < 16; i++) {
    mbDqcoeff[mbDqcoeffOffset + i * 16] = a1;
  }
}
