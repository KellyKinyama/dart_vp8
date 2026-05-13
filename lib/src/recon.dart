// Per-macroblock reconstruction: dequant + IWHT (if Y2) + predict + IDCT-add.
//
// Supports both intra MBs (DC/V/H/TM/B_PRED) via [reconstructMb] and inter
// MBs (ZEROMV / NEARESTMV / NEARMV / NEWMV / SPLITMV) via
// [reconstructMbInter].

import 'dart:typed_data';

import 'entropy.dart' show kZigzag;
import 'idct.dart';
import 'inter_pred.dart';
import 'intra_pred.dart';
import 'mode_info.dart';
import 'mv.dart';
import 'quant.dart';
import 'ref_frame.dart';

/// Border fill values used by VP8 when neighbours are unavailable
/// (vp8/common/reconintra.c). The top row is 127, the left column is 129,
/// the top-left corner is 127.
const int _borderAbove = 127;
const int _borderLeft = 129;
const int _borderCorner = 127;

/// In-place dequant: multiply coefficient[i] by `(i == 0 ? dc : ac)`.
void _dequantBlock(Int16List coeff, int off, int dc, int ac) {
  coeff[off] = (coeff[off] * dc).toSigned(32);
  for (int i = 1; i < 16; i++) {
    coeff[off + i] = (coeff[off + i] * ac).toSigned(32);
  }
}

/// Reconstruct a single 16x16 luma block and the matching 8x8 U/V blocks.
/// Coefficients in `qcoeff` are dequantized in place.
///
/// `mi.yMode == bPred` is not yet supported.
void reconstructMb({
  required ModeInfo mi,
  required Int16List qcoeff,
  required Uint8List eobs,
  required DequantSet dq,
  required Uint8List yPlane,
  required Uint8List uPlane,
  required Uint8List vPlane,
  required int mbCol,
  required int mbRow,
  required int mbCols,
  required int yStride,
  required int uvStride,
}) {
  if (mi.yMode == bPred) {
    _reconstructLumaBpred(
      mi: mi,
      qcoeff: qcoeff,
      eobs: eobs,
      dq: dq,
      yPlane: yPlane,
      mbCol: mbCol,
      mbRow: mbRow,
      mbCols: mbCols,
      yStride: yStride,
    );
    // Dequant UV blocks separately (no IWHT, no Y dequant scaling).
    if (!mi.skipCoeff) {
      for (int b = 16; b < 24; b++) {
        _dequantBlock(qcoeff, b * 16, dq.uvDc, dq.uvAc);
      }
    }
  } else {
    // ---- 1. Dequant + IWHT for Y2 (luma DC plane) ----
    if (!mi.skipCoeff) {
      // Y2 block: index 24, two-pair dequant (y2Dc / y2Ac).
      _dequantBlock(qcoeff, 24 * 16, dq.y2Dc, dq.y2Ac);

      // Inverse Walsh distributes the 16 DCs into Y blocks 0..15 at slot 0.
      if (eobs[24] > 1) {
        inverseWalsh4x4(qcoeff, 24 * 16, qcoeff, 0);
      } else {
        inverseWalsh4x4Dc(qcoeff[24 * 16], qcoeff, 0);
      }

      // Y blocks 0..15: AC-only dequant (DC already set by IWHT).
      for (int b = 0; b < 16; b++) {
        // DC slot already contains the IWHT'd value -- do NOT scale it.
        for (int i = 1; i < 16; i++) {
          qcoeff[b * 16 + i] = (qcoeff[b * 16 + i] * dq.y1Ac).toSigned(32);
        }
      }

      // UV blocks 16..23: full DC+AC dequant.
      for (int b = 16; b < 24; b++) {
        _dequantBlock(qcoeff, b * 16, dq.uvDc, dq.uvAc);
      }
    }

    // ---- 2. Gather above row / left column for Y prediction ----
    final int yMbOff = mbRow * 16 * yStride + mbCol * 16;

    final Uint8List above16 = Uint8List(16);
    final Uint8List left16 = Uint8List(16);
    int yTopLeft;
    final bool upAvailY = mbRow > 0;
    final bool leftAvailY = mbCol > 0;
    if (upAvailY) {
      final int aboveRow = yMbOff - yStride;
      for (int i = 0; i < 16; i++) {
        above16[i] = yPlane[aboveRow + i];
      }
    } else {
      for (int i = 0; i < 16; i++) {
        above16[i] = _borderAbove;
      }
    }
    if (leftAvailY) {
      for (int r = 0; r < 16; r++) {
        left16[r] = yPlane[yMbOff + r * yStride - 1];
      }
    } else {
      for (int r = 0; r < 16; r++) {
        left16[r] = _borderLeft;
      }
    }
    if (upAvailY && leftAvailY) {
      yTopLeft = yPlane[yMbOff - yStride - 1];
    } else if (upAvailY) {
      yTopLeft = _borderLeft;
    } else if (leftAvailY) {
      yTopLeft = _borderAbove;
    } else {
      yTopLeft = _borderCorner;
    }

    // ---- 3. Predict 16x16 Y into the destination ----
    predict16x16(
      mi.yMode,
      yPlane,
      yMbOff,
      yStride,
      above16,
      0,
      left16,
      0,
      yTopLeft,
      upAvailY,
      leftAvailY,
    );

    // ---- 4. IDCT-add the 16 luma residual blocks ----
    if (!mi.skipCoeff || eobs[24] > 0) {
      for (int b = 0; b < 16; b++) {
        final int eob = eobs[b];
        final int br = b >> 2;
        final int bc = b & 3;
        final int blockOff = yMbOff + br * 4 * yStride + bc * 4;
        _addBlockResidual(qcoeff, b * 16, eob, yPlane, blockOff, yStride);
      }
    }
  }

  // ---- 5. Gather above row / left column for UV prediction ----
  for (final entry in <List<Object>>[
    <Object>[uPlane, 16],
    <Object>[vPlane, 20],
  ]) {
    final Uint8List plane = entry[0] as Uint8List;
    final int firstBlock = entry[1] as int;
    final int mbOff = mbRow * 8 * uvStride + mbCol * 8;
    final bool upAvail = mbRow > 0;
    final bool leftAvail = mbCol > 0;
    final Uint8List above8 = Uint8List(8);
    final Uint8List left8 = Uint8List(8);
    int topLeft;
    if (upAvail) {
      final int aboveRow = mbOff - uvStride;
      for (int i = 0; i < 8; i++) {
        above8[i] = plane[aboveRow + i];
      }
    } else {
      for (int i = 0; i < 8; i++) {
        above8[i] = _borderAbove;
      }
    }
    if (leftAvail) {
      for (int r = 0; r < 8; r++) {
        left8[r] = plane[mbOff + r * uvStride - 1];
      }
    } else {
      for (int r = 0; r < 8; r++) {
        left8[r] = _borderLeft;
      }
    }
    if (upAvail && leftAvail) {
      topLeft = plane[mbOff - uvStride - 1];
    } else if (upAvail) {
      topLeft = _borderLeft;
    } else if (leftAvail) {
      topLeft = _borderAbove;
    } else {
      topLeft = _borderCorner;
    }

    predict8x8(
      mi.uvMode,
      plane,
      mbOff,
      uvStride,
      above8,
      0,
      left8,
      0,
      topLeft,
      upAvail,
      leftAvail,
    );

    if (!mi.skipCoeff) {
      for (int b = firstBlock; b < firstBlock + 4; b++) {
        final int eob = eobs[b];
        final int sub = b - firstBlock;
        final int br = sub >> 1;
        final int bc = sub & 1;
        final int blockOff = mbOff + br * 4 * uvStride + bc * 4;
        _addBlockResidual(qcoeff, b * 16, eob, plane, blockOff, uvStride);
      }
    }
  }
}

/// Reconstruct the 16 Y blocks of a B_PRED macroblock. Each 4x4 block has
/// its own intra-prediction mode (`mi.bModes[b]`), predicted from samples
/// that may live in:
///   * the row immediately above the current MB (for top blocks), or
///   * already-reconstructed pixels from blocks earlier in the same MB.
///
/// The "above-right" 4 samples used by some modes for blocks at column 3
/// of any sub-row are taken from the same 4 samples that would lie in the
/// MB diagonally above-right of us -- libvpx mirrors this with an explicit
/// down_copy; we read directly from the Y plane (or border-fill).
void _reconstructLumaBpred({
  required ModeInfo mi,
  required Int16List qcoeff,
  required Uint8List eobs,
  required DequantSet dq,
  required Uint8List yPlane,
  required int mbCol,
  required int mbRow,
  required int mbCols,
  required int yStride,
}) {
  // Per-block Y dequant: each block has its own DC (no Y2 in B_PRED).
  if (!mi.skipCoeff) {
    for (int b = 0; b < 16; b++) {
      _dequantBlock(qcoeff, b * 16, dq.y1Dc, dq.y1Ac);
    }
  }

  final int yMbOff = mbRow * 16 * yStride + mbCol * 16;
  final bool upAvail = mbRow > 0;
  final bool leftAvail = mbCol > 0;

  // Pre-compute the 4-sample "above-right" window for blocks at bc=3.
  // Position: the row above the MB at columns 16..19 of the MB.
  final Uint8List aboveRight = Uint8List(4);
  if (upAvail) {
    if (mbCol < mbCols - 1) {
      final int base = yMbOff - yStride + 16;
      for (int i = 0; i < 4; i++) {
        aboveRight[i] = yPlane[base + i];
      }
    } else {
      // No MB to the right -- replicate the topmost-rightmost pixel of
      // the row above the MB. (Matches libvpx's recon_above padding.)
      final int rep = yPlane[yMbOff - yStride + 15];
      for (int i = 0; i < 4; i++) {
        aboveRight[i] = rep;
      }
    }
  } else {
    // Top row of frame: above-row is the 127 border.
    for (int i = 0; i < 4; i++) {
      aboveRight[i] = _borderAbove;
    }
  }

  final Uint8List above8 = Uint8List(8);
  final Uint8List left4 = Uint8List(4);

  for (int b = 0; b < 16; b++) {
    final int br = b >> 2;
    final int bc = b & 3;
    final int blockOff = yMbOff + br * 4 * yStride + bc * 4;

    // Build above[0..7].
    if (br > 0) {
      // Source = row (br*4 - 1) of current MB at columns bc*4..bc*4+3,
      // and either continuing pixels for bc<3 or aboveRight for bc==3.
      final int aboveBase = blockOff - yStride;
      for (int i = 0; i < 4; i++) {
        above8[i] = yPlane[aboveBase + i];
      }
      if (bc < 3) {
        for (int i = 0; i < 4; i++) {
          above8[4 + i] = yPlane[aboveBase + 4 + i];
        }
      } else {
        for (int i = 0; i < 4; i++) {
          above8[4 + i] = aboveRight[i];
        }
      }
    } else {
      // Top row of MB: read from the row immediately above the MB.
      if (upAvail) {
        final int aboveBase = yMbOff - yStride + bc * 4;
        for (int i = 0; i < 4; i++) {
          above8[i] = yPlane[aboveBase + i];
        }
        if (bc < 3) {
          for (int i = 0; i < 4; i++) {
            above8[4 + i] = yPlane[aboveBase + 4 + i];
          }
        } else {
          for (int i = 0; i < 4; i++) {
            above8[4 + i] = aboveRight[i];
          }
        }
      } else {
        for (int i = 0; i < 8; i++) {
          above8[i] = _borderAbove;
        }
      }
    }

    // Build left[0..3].
    if (bc > 0) {
      for (int r = 0; r < 4; r++) {
        left4[r] = yPlane[blockOff + r * yStride - 1];
      }
    } else {
      // Leftmost column of MB.
      if (leftAvail) {
        for (int r = 0; r < 4; r++) {
          left4[r] = yPlane[blockOff + r * yStride - 1];
        }
      } else {
        for (int r = 0; r < 4; r++) {
          left4[r] = _borderLeft;
        }
      }
    }

    // Build topLeft: pixel at (br*4 - 1, bc*4 - 1) relative to MB.
    int topLeft;
    if (br > 0 && bc > 0) {
      topLeft = yPlane[blockOff - yStride - 1];
    } else if (br == 0 && bc > 0) {
      // Above the block: row above MB at column bc*4 - 1.
      if (upAvail) {
        topLeft = yPlane[yMbOff - yStride + bc * 4 - 1];
      } else {
        topLeft = _borderAbove;
      }
    } else if (br > 0 && bc == 0) {
      // Left of the block: left column at row br*4 - 1.
      if (leftAvail) {
        topLeft = yPlane[blockOff - yStride - 1];
      } else {
        topLeft = _borderLeft;
      }
    } else {
      // br == 0 && bc == 0: above-left corner of the MB.
      if (upAvail && leftAvail) {
        topLeft = yPlane[yMbOff - yStride - 1];
      } else if (upAvail) {
        topLeft = _borderLeft;
      } else if (leftAvail) {
        topLeft = _borderAbove;
      } else {
        topLeft = _borderCorner;
      }
    }

    predict4x4(
      mi.bModes[b],
      yPlane,
      blockOff,
      yStride,
      topLeft,
      above8,
      0,
      left4,
      0,
    );

    // Add residual.
    _addBlockResidual(qcoeff, b * 16, eobs[b], yPlane, blockOff, yStride);
  }
}

/// Add the inverse-DCT of one 4x4 residual block to `dst` at `dstOff`.
void _addBlockResidual(Int16List coeff, int coeffOff, int eob, Uint8List dst,
    int dstOff, int dstStride) {
  if (eob == 0) {
    // No residual: nothing to add. The block is already filled by the
    // predictor, so we're done.
    return;
  }
  if (eob == 1) {
    // DC-only. Note that after IWHT (for non-4x4 MBs), `coeff[coeffOff]`
    // holds the AC-distributed value already; for 4x4 (B_PRED) blocks
    // dc came from the regular dequant path. Either way the helper sees
    // the same final scalar.
    dcOnlyIdct4x4Add(
        coeff[coeffOff], dst, dstOff, dstStride, dst, dstOff, dstStride);
    // Clear DC for next pass.
    coeff[coeffOff] = 0;
    return;
  }
  // Coefficients in `coeff[coeffOff..+16]` are stored in raster (post-zigzag)
  // order already; idct4x4Add consumes them directly.
  idct4x4Add(coeff, coeffOff, dst, dstOff, dstStride, dst, dstOff, dstStride);
  // Zero coefficients in case the buffer is reused.
  for (int i = 0; i < 16; i++) {
    coeff[coeffOff + i] = 0;
  }
}

// Suppress "unused" warning for kZigzag re-export when entropy.dart's
// users don't already import it.
// ignore: unused_element
List<int> get _zigzag => kZigzag;

// =========================================================================
// Inter-MB reconstruction (Stage 7B).
// =========================================================================

/// Dequant + Y2 IWHT distribute, AC scale Y, full dequant UV. Identical to
/// the non-bPred intra path's setup; factored out so the inter path can
/// reuse it.
void _dequantAndDistributeY2({
  required Int16List qcoeff,
  required Uint8List eobs,
  required DequantSet dq,
}) {
  _dequantBlock(qcoeff, 24 * 16, dq.y2Dc, dq.y2Ac);
  if (eobs[24] > 1) {
    inverseWalsh4x4(qcoeff, 24 * 16, qcoeff, 0);
  } else {
    inverseWalsh4x4Dc(qcoeff[24 * 16], qcoeff, 0);
  }
  for (int b = 0; b < 16; b++) {
    for (int i = 1; i < 16; i++) {
      qcoeff[b * 16 + i] = (qcoeff[b * 16 + i] * dq.y1Ac).toSigned(32);
    }
  }
  for (int b = 16; b < 24; b++) {
    _dequantBlock(qcoeff, b * 16, dq.uvDc, dq.uvAc);
  }
}

/// Inter-predict a 16x16 luma block using sixtap (or bilinear when
/// `useBilinear` is true) into `yPlane` at the MB position.
void _interPredictY16x16({
  required RefFrame ref,
  required Mv mv,
  required Uint8List yPlane,
  required int yMbOff,
  required int yStride,
  required int mbCol,
  required int mbRow,
  required bool useBilinear,
}) {
  // mv is in 1/8-pel luma units. Integer part = mv >> 3 (arith shift).
  int intRow = mv.row >> 3;
  int intCol = mv.col >> 3;
  final int subRow = mv.row & 7;
  final int subCol = mv.col & 7;

  // Clamp integer mv part so the sixtap access region (16+5 = 21 samples,
  // reaching -2..+18 from the MB top-left) stays inside the bordered ref
  // buffer. libvpx does the equivalent in vp8_build_inter_predictors_mb via
  // clamp_mv_to_umv_border_sb. Without this we can underflow into negative
  // buffer indices for streams with large MVs.
  final int bufRows = ref.y.length ~/ ref.yStride;
  // Required range in *buffer* (origin-adjusted) coords:
  //   row in [yBorder + mbRow*16 + intRow - 2, yBorder + mbRow*16 + intRow + 18]
  // must fit [0, bufRows - 1].
  final int rowBase = yBorder + mbRow * 16;
  final int colBase = yBorder + mbCol * 16;
  int loRow = -(rowBase - 2);
  int hiRow = bufRows - 1 - 18 - rowBase;
  int loCol = -(colBase - 2);
  int hiCol = ref.yStride - 1 - 18 - colBase;
  if (intRow < loRow) intRow = loRow;
  if (intRow > hiRow) intRow = hiRow;
  if (intCol < loCol) intCol = loCol;
  if (intCol > hiCol) intCol = hiCol;

  // Top-left integer source position in ref Y plane.
  final int srcOff =
      ref.yOrigin + (mbRow * 16 + intRow) * ref.yStride + (mbCol * 16 + intCol);

  // The 16x16 predict needs to write into the current Y plane; the
  // sixtap/bilinear predictors take (src, srcOff, srcStride, xoffset,
  // yoffset, dst, dstOff, dstStride).
  if (useBilinear) {
    bilinearPredict16x16(
        ref.y, srcOff, ref.yStride, subCol, subRow, yPlane, yMbOff, yStride);
  } else {
    sixtapPredict16x16(
        ref.y, srcOff, ref.yStride, subCol, subRow, yPlane, yMbOff, yStride);
  }
}

/// Inter-predict a single 8x8 chroma plane.
void _interPredictUv8x8({
  required Uint8List refPlane,
  required int refOrigin,
  required int refStride,
  required int chromaMvRow,
  required int chromaMvCol,
  required Uint8List dstPlane,
  required int dstOff,
  required int dstStride,
  required int mbCol,
  required int mbRow,
  required bool useBilinear,
}) {
  int intRow = chromaMvRow >> 3;
  int intCol = chromaMvCol >> 3;
  final int subRow = chromaMvRow & 7;
  final int subCol = chromaMvCol & 7;
  // Clamp so the 8x8 sixtap access region (reach -2..+10) fits.
  final int bufRows = refPlane.length ~/ refStride;
  final int rowBase = uvBorder + mbRow * 8;
  final int colBase = uvBorder + mbCol * 8;
  int loRow = -(rowBase - 2);
  int hiRow = bufRows - 1 - 10 - rowBase;
  int loCol = -(colBase - 2);
  int hiCol = refStride - 1 - 10 - colBase;
  if (intRow < loRow) intRow = loRow;
  if (intRow > hiRow) intRow = hiRow;
  if (intCol < loCol) intCol = loCol;
  if (intCol > hiCol) intCol = hiCol;
  final int srcOff =
      refOrigin + (mbRow * 8 + intRow) * refStride + (mbCol * 8 + intCol);
  if (useBilinear) {
    bilinearPredict8x8(refPlane, srcOff, refStride, subCol, subRow, dstPlane,
        dstOff, dstStride);
  } else {
    sixtapPredict8x8(refPlane, srcOff, refStride, subCol, subRow, dstPlane,
        dstOff, dstStride);
  }
}

/// Reconstruct a single non-SPLITMV inter MB: predict from [ref] using
/// [mi.mv], add Y2+IDCT residual, predict UV with averaged chroma MV, add
/// chroma residual.
void reconstructMbInter({
  required ModeInfo mi,
  required Int16List qcoeff,
  required Uint8List eobs,
  required DequantSet dq,
  required RefFrame ref,
  required Uint8List yPlane,
  required Uint8List uPlane,
  required Uint8List vPlane,
  required int mbCol,
  required int mbRow,
  required int yStride,
  required int uvStride,
  required bool useBilinear,
  /// VP8 version=3 sets `xd->fullpixel_mask = ~7`, which masks the chroma
  /// motion vector to a multiple of 8 (full-pixel only) after derivation.
  required bool useFullPixel,
}) {
  if (mi.yMode == splitMv) {
    _reconstructMbSplitMv(
      mi: mi,
      qcoeff: qcoeff,
      eobs: eobs,
      dq: dq,
      ref: ref,
      yPlane: yPlane,
      uPlane: uPlane,
      vPlane: vPlane,
      mbCol: mbCol,
      mbRow: mbRow,
      yStride: yStride,
      uvStride: uvStride,
      useBilinear: useBilinear,
      useFullPixel: useFullPixel,
    );
    return;
  }

  // 1. Dequant + Y2 IWHT distribute (skipped when skipCoeff).
  if (!mi.skipCoeff) {
    _dequantAndDistributeY2(qcoeff: qcoeff, eobs: eobs, dq: dq);
  }

  // 2. Y prediction from ref via sixtap/bilinear.
  final int yMbOff = mbRow * 16 * yStride + mbCol * 16;
  _interPredictY16x16(
    ref: ref,
    mv: mi.mv,
    yPlane: yPlane,
    yMbOff: yMbOff,
    yStride: yStride,
    mbCol: mbCol,
    mbRow: mbRow,
    useBilinear: useBilinear,
  );

  // 3. Y IDCT-add residual.
  if (!mi.skipCoeff || eobs[24] > 0) {
    for (int b = 0; b < 16; b++) {
      final int eob = eobs[b];
      final int br = b >> 2;
      final int bc = b & 3;
      final int blockOff = yMbOff + br * 4 * yStride + bc * 4;
      _addBlockResidual(qcoeff, b * 16, eob, yPlane, blockOff, yStride);
    }
  }

  // 4. Chroma MV: collapse 4 luma sub-MVs (which are all equal to mi.mv
  //    for non-split modes) per the libvpx (sum ± 4)/8 rule.
  int chromaMvRow = chromaMvFromLumaSum(4 * mi.mv.row);
  int chromaMvCol = chromaMvFromLumaSum(4 * mi.mv.col);
  if (useFullPixel) {
    // Full-pixel mode (version=3): drop the sub-pel bits, matching
    // `& xd->fullpixel_mask` (`& ~7`) in vp8/common/reconinter.c.
    chromaMvRow &= ~7;
    chromaMvCol &= ~7;
  }

  final int uvMbOff = mbRow * 8 * uvStride + mbCol * 8;

  _interPredictUv8x8(
    refPlane: ref.u,
    refOrigin: ref.uvOrigin,
    refStride: ref.uvStride,
    chromaMvRow: chromaMvRow,
    chromaMvCol: chromaMvCol,
    dstPlane: uPlane,
    dstOff: uvMbOff,
    dstStride: uvStride,
    mbCol: mbCol,
    mbRow: mbRow,
    useBilinear: useBilinear,
  );
  _interPredictUv8x8(
    refPlane: ref.v,
    refOrigin: ref.uvOrigin,
    refStride: ref.uvStride,
    chromaMvRow: chromaMvRow,
    chromaMvCol: chromaMvCol,
    dstPlane: vPlane,
    dstOff: uvMbOff,
    dstStride: uvStride,
    mbCol: mbCol,
    mbRow: mbRow,
    useBilinear: useBilinear,
  );

  // 5. Chroma IDCT-add residual.
  if (!mi.skipCoeff) {
    for (final entry in <List<Object>>[
      <Object>[uPlane, 16],
      <Object>[vPlane, 20],
    ]) {
      final Uint8List plane = entry[0] as Uint8List;
      final int firstBlock = entry[1] as int;
      for (int b = firstBlock; b < firstBlock + 4; b++) {
        final int eob = eobs[b];
        final int sub = b - firstBlock;
        final int br = sub >> 1;
        final int bc = sub & 1;
        final int blockOff = uvMbOff + br * 4 * uvStride + bc * 4;
        _addBlockResidual(qcoeff, b * 16, eob, plane, blockOff, uvStride);
      }
    }
  }
}

// SPLITMV reconstruction: 16 per-4x4 luma MVs + per-4x4 chroma MVs.
void _reconstructMbSplitMv({
  required ModeInfo mi,
  required Int16List qcoeff,
  required Uint8List eobs,
  required DequantSet dq,
  required RefFrame ref,
  required Uint8List yPlane,
  required Uint8List uPlane,
  required Uint8List vPlane,
  required int mbCol,
  required int mbRow,
  required int yStride,
  required int uvStride,
  required bool useBilinear,
  required bool useFullPixel,
}) {
  // SPLITMV is4x4 -> per-block AC/DC dequant for all 16 Y blocks (no Y2).
  if (!mi.skipCoeff) {
    for (int b = 0; b < 16; b++) {
      _dequantBlock(qcoeff, b * 16, dq.y1Dc, dq.y1Ac);
    }
    for (int b = 16; b < 24; b++) {
      _dequantBlock(qcoeff, b * 16, dq.uvDc, dq.uvAc);
    }
  }

  final int yMbOff = mbRow * 16 * yStride + mbCol * 16;
  // Per-4x4 Y inter predict.
  final int yBufRows = ref.y.length ~/ ref.yStride;
  for (int b = 0; b < 16; b++) {
    final int br = b >> 2;
    final int bc = b & 3;
    final int packed = mi.bMvs[b];
    final int row = unpackBMvRow(packed);
    final int col = unpackBMvCol(packed);
    int intRow = row >> 3;
    int intCol = col >> 3;
    final int subRow = row & 7;
    final int subCol = col & 7;
    // Clamp so the 4x4 sixtap reach (-2..+6) stays inside the bordered ref.
    final int rowBase = yBorder + mbRow * 16 + br * 4;
    final int colBase = yBorder + mbCol * 16 + bc * 4;
    final int loRow = -(rowBase - 2);
    final int hiRow = yBufRows - 1 - 6 - rowBase;
    final int loCol = -(colBase - 2);
    final int hiCol = ref.yStride - 1 - 6 - colBase;
    if (intRow < loRow) intRow = loRow;
    if (intRow > hiRow) intRow = hiRow;
    if (intCol < loCol) intCol = loCol;
    if (intCol > hiCol) intCol = hiCol;
    final int srcOff = ref.yOrigin +
        (mbRow * 16 + br * 4 + intRow) * ref.yStride +
        (mbCol * 16 + bc * 4 + intCol);
    final int dstOff = yMbOff + br * 4 * yStride + bc * 4;
    if (useBilinear) {
      bilinearPredict4x4(
          ref.y, srcOff, ref.yStride, subCol, subRow, yPlane, dstOff, yStride);
    } else {
      sixtapPredict4x4(
          ref.y, srcOff, ref.yStride, subCol, subRow, yPlane, dstOff, yStride);
    }
  }

  // Y residual add.
  if (!mi.skipCoeff) {
    for (int b = 0; b < 16; b++) {
      final int br = b >> 2;
      final int bc = b & 3;
      final int blockOff = yMbOff + br * 4 * yStride + bc * 4;
      _addBlockResidual(qcoeff, b * 16, eobs[b], yPlane, blockOff, yStride);
    }
  }

  // Chroma: 4 quadrants. Each quadrant aggregates 4 luma MVs (a 2x2 of
  // luma 4x4 blocks) into one chroma MV via libvpx's (sum +- 4) / 8 rule.
  final int uvMbOff = mbRow * 8 * uvStride + mbCol * 8;
  for (int qi = 0; qi < 4; qi++) {
    final int qr = qi >> 1; // 0..1
    final int qc = qi & 1;
    final int yBase = qr * 8 + qc * 2; // top-left luma block index
    int sumRow = 0;
    int sumCol = 0;
    for (int dr = 0; dr < 2; dr++) {
      for (int dc = 0; dc < 2; dc++) {
        final int packed = mi.bMvs[yBase + dr * 4 + dc];
        sumRow += unpackBMvRow(packed);
        sumCol += unpackBMvCol(packed);
      }
    }
    final int uvRow0 = chromaMvFromLumaSum(sumRow);
    final int uvCol0 = chromaMvFromLumaSum(sumCol);
    final int uvRow = useFullPixel ? (uvRow0 & ~7) : uvRow0;
    final int uvCol = useFullPixel ? (uvCol0 & ~7) : uvCol0;
    int intRow = uvRow >> 3;
    int intCol = uvCol >> 3;
    final int subRow = uvRow & 7;
    final int subCol = uvCol & 7;
    // Chroma block top-left within MB: each quadrant is 4x4 chroma px.
    final int blockRowChromaPx = qr * 4;
    final int blockColChromaPx = qc * 4;
    final int dstOff = uvMbOff + blockRowChromaPx * uvStride + blockColChromaPx;
    // Clamp the integer mv so the 4x4 sixtap reach (-2..+6) stays inside.
    final int uvBufRows = ref.u.length ~/ ref.uvStride;
    final int rowBaseUv = uvBorder + mbRow * 8 + blockRowChromaPx;
    final int colBaseUv = uvBorder + mbCol * 8 + blockColChromaPx;
    final int loRowUv = -(rowBaseUv - 2);
    final int hiRowUv = uvBufRows - 1 - 6 - rowBaseUv;
    final int loColUv = -(colBaseUv - 2);
    final int hiColUv = ref.uvStride - 1 - 6 - colBaseUv;
    if (intRow < loRowUv) intRow = loRowUv;
    if (intRow > hiRowUv) intRow = hiRowUv;
    if (intCol < loColUv) intCol = loColUv;
    if (intCol > hiColUv) intCol = hiColUv;
    final int srcOff = ref.uvOrigin +
        (mbRow * 8 + blockRowChromaPx + intRow) * ref.uvStride +
        (mbCol * 8 + blockColChromaPx + intCol);
    if (useBilinear) {
      bilinearPredict4x4(ref.u, srcOff, ref.uvStride, subCol, subRow, uPlane,
          dstOff, uvStride);
      bilinearPredict4x4(ref.v, srcOff, ref.uvStride, subCol, subRow, vPlane,
          dstOff, uvStride);
    } else {
      sixtapPredict4x4(ref.u, srcOff, ref.uvStride, subCol, subRow, uPlane,
          dstOff, uvStride);
      sixtapPredict4x4(ref.v, srcOff, ref.uvStride, subCol, subRow, vPlane,
          dstOff, uvStride);
    }
  }

  // Chroma residual add.
  if (!mi.skipCoeff) {
    for (final entry in <List<Object>>[
      <Object>[uPlane, 16],
      <Object>[vPlane, 20],
    ]) {
      final Uint8List plane = entry[0] as Uint8List;
      final int firstBlock = entry[1] as int;
      for (int b = firstBlock; b < firstBlock + 4; b++) {
        final int eob = eobs[b];
        final int sub = b - firstBlock;
        final int br = sub >> 1;
        final int bc = sub & 1;
        final int blockOff = uvMbOff + br * 4 * uvStride + bc * 4;
        _addBlockResidual(qcoeff, b * 16, eob, plane, blockOff, uvStride);
      }
    }
  }
}
