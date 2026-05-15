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
///
/// SIMD: the column pass is a pure 4-wide additive butterfly across the
/// four rows of the input — a perfect fit for `Int32x4`. The row pass is
/// also expressed via `Int32x4` shuffles so both stages stay in SIMD
/// registers. Results are bit-exact vs the scalar reference.
void inverseWalsh4x4(
  Int16List input,
  int inputOffset,
  Int16List mbDqcoeff,
  int mbDqcoeffOffset,
) {
  // Load the four input rows as Int32x4 (sign-extended from int16).
  final Int32x4 r0 = Int32x4(
    input[inputOffset + 0],
    input[inputOffset + 1],
    input[inputOffset + 2],
    input[inputOffset + 3],
  );
  final Int32x4 r1 = Int32x4(
    input[inputOffset + 4],
    input[inputOffset + 5],
    input[inputOffset + 6],
    input[inputOffset + 7],
  );
  final Int32x4 r2 = Int32x4(
    input[inputOffset + 8],
    input[inputOffset + 9],
    input[inputOffset + 10],
    input[inputOffset + 11],
  );
  final Int32x4 r3 = Int32x4(
    input[inputOffset + 12],
    input[inputOffset + 13],
    input[inputOffset + 14],
    input[inputOffset + 15],
  );

  // Pass 1: column butterfly across rows. Each lane handles one column.
  final Int32x4 a = r0 + r3; // a1
  final Int32x4 b = r1 + r2; // b1
  final Int32x4 c = r1 - r2; // c1
  final Int32x4 d = r0 - r3; // d1

  // Post-column rows.
  final Int32x4 p0 = a + b; // row 0 of intermediate
  final Int32x4 p1 = c + d; // row 1
  final Int32x4 p2 = a - b; // row 2
  final Int32x4 p3 = d - c; // row 3

  // Pass 2: row butterfly. Each Int32x4 holds one row (v0,v1,v2,v3).
  // Compute (a1+b1, c1+d1, a1-b1, d1-c1) per row. With v0,v1,v2,v3:
  //   a1=v0+v3, b1=v1+v2, c1=v1-v2, d1=v0-v3.
  // We need v3,v2,v1,v0 in a shuffled vector. Int32x4.shuffle mask packs
  // the four 2-bit lane selectors as bits 1:0=x, 3:2=y, 5:4=z, 7:6=w.
  // Mask 0x1B = 0b00_01_10_11 means new=(src.w, src.z, src.y, src.x).
  const int rev = 0x1B;

  // For row r=(v0,v1,v2,v3), p+rev = (v0+v3, v1+v2, v2+v1, v3+v0) = (a1,b1,b1,a1).
  // p-rev = (v0-v3, v1-v2, v2-v1, v3-v0) = (d1, c1, -c1, -d1).
  // Output row = (a1+b1, c1+d1, a1-b1, d1-c1).
  //   lane 0: sum.x + sum.y       = a1+b1
  //   lane 1: -diff.x + (-diff.y * -1) ... use diff: diff.x=d1, diff.y=c1
  //           so c1+d1 = diff.x + diff.y
  //   lane 2: sum.x - sum.y       = a1-b1
  //   lane 3: diff.x - diff.y     = d1-c1
  // Build vectors: addPair = (sum.x, diff.x, sum.x, diff.x);
  //                subPair = (sum.y, diff.y, sum.y, diff.y);
  // out_unshifted = addPair +/- subPair per-lane, but we need mixed signs:
  //   lanes 0,1 are add; lanes 2,3 are sub. Solve by negating subPair lanes
  //   2,3. Cheapest path: do the row pass via two scalar SIMD ops:
  //   tmpAdd = sum  (a1, b1, *, *)
  //   tmpSub = diff (d1, c1, *, *)
  //   then assemble result via withX/Y/Z/W.

  Int32x4 _rowPass(Int32x4 row) {
    final Int32x4 swp = row.shuffle(rev); // (v3, v2, v1, v0)
    final Int32x4 sm = row + swp; // (a1, b1, b1, a1)
    final Int32x4 df = row - swp; // (d1, c1, -c1, -d1)
    final int a1 = sm.x;
    final int b1 = sm.y;
    final int c1 = df.y;
    final int d1 = df.x;
    // Build (a1+b1+3, c1+d1+3, a1-b1+3, d1-c1+3) then >>3.
    return Int32x4(
      (a1 + b1 + 3) >> 3,
      (c1 + d1 + 3) >> 3,
      (a1 - b1 + 3) >> 3,
      (d1 - c1 + 3) >> 3,
    );
  }

  final Int32x4 q0 = _rowPass(p0);
  final Int32x4 q1 = _rowPass(p1);
  final Int32x4 q2 = _rowPass(p2);
  final Int32x4 q3 = _rowPass(p3);

  // Scatter to the 16 luma 4x4 blocks' DC slots.
  // Row-major i = r*4+c; target index = mbDqcoeffOffset + i*16.
  mbDqcoeff[mbDqcoeffOffset + 0 * 16] = q0.x;
  mbDqcoeff[mbDqcoeffOffset + 1 * 16] = q0.y;
  mbDqcoeff[mbDqcoeffOffset + 2 * 16] = q0.z;
  mbDqcoeff[mbDqcoeffOffset + 3 * 16] = q0.w;
  mbDqcoeff[mbDqcoeffOffset + 4 * 16] = q1.x;
  mbDqcoeff[mbDqcoeffOffset + 5 * 16] = q1.y;
  mbDqcoeff[mbDqcoeffOffset + 6 * 16] = q1.z;
  mbDqcoeff[mbDqcoeffOffset + 7 * 16] = q1.w;
  mbDqcoeff[mbDqcoeffOffset + 8 * 16] = q2.x;
  mbDqcoeff[mbDqcoeffOffset + 9 * 16] = q2.y;
  mbDqcoeff[mbDqcoeffOffset + 10 * 16] = q2.z;
  mbDqcoeff[mbDqcoeffOffset + 11 * 16] = q2.w;
  mbDqcoeff[mbDqcoeffOffset + 12 * 16] = q3.x;
  mbDqcoeff[mbDqcoeffOffset + 13 * 16] = q3.y;
  mbDqcoeff[mbDqcoeffOffset + 14 * 16] = q3.z;
  mbDqcoeff[mbDqcoeffOffset + 15 * 16] = q3.w;
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
