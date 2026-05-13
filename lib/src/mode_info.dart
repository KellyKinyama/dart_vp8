// Per-macroblock mode info and the mode-decoding loops for both key
// frames and inter frames.
//
// Port of:
//   * vp8/decoder/decodemv.c::read_kf_modes      (keyframe path)
//   * vp8/decoder/decodemv.c::read_mb_modes_mv   (inter path)
//   * vp8/common/findnearmv.c                    (find_near_mvs context)

import 'dart:typed_data';

import 'bool_decoder.dart';
import 'constants/mode_mv_probs.dart';
import 'frame_header.dart';
import 'intra_pred.dart';
import 'mv.dart';
import 'mv_decode.dart';
import 'tree.dart';

/// Mode info for a single macroblock (keyframe-only fields for now).
class ModeInfo {
  /// Y prediction mode: one of [dcPred], [vPred], [hPred], [tmPred], [bPred].
  int yMode = 0;

  /// UV prediction mode (DC/V/H/TM only -- bPred not allowed for UV).
  int uvMode = 0;

  /// Per-4x4 luma B-modes. Valid only when [yMode] == [bPred]. Length 16,
  /// raster order.
  final Uint8List bModes = Uint8List(16);

  /// 0..3 (only nonzero if frame-level segmentation is enabled and the
  /// map is being updated this frame).
  int segmentId = 0;

  /// Per-MB skip-residual flag.
  bool skipCoeff = false;

  /// Reference frame: 0 = intra, 1 = LAST, 2 = GOLDEN, 3 = ALTREF.
  int refFrame = 0;

  /// Macroblock-level MV (1/8-pel units). Zero for intra MBs.
  final Mv mv = Mv();

  /// Per-4x4 sub-block MVs. For non-split modes all 16 entries equal `mv`
  /// (or zero for intra). Populated by inter mode decode.
  final Int32List bMvs = Int32List(16); // row<<16 | col, both as int16

  /// SPLITMV partitioning index 0..3 (= 16x8 / 8x16 / 8x8 / 4x4). -1 if
  /// the MB is not SPLITMV.
  int partitioning = -1;

  /// Maximum end-of-block index across all 25 blocks of this MB. Set
  /// during token decode (zero for skipped MBs). Used by the loop filter
  /// to gate inner-edge filtering, per VP8 spec section 15.
  int eobMax = 0;

  /// True when the macroblock uses 4x4 luma prediction. Equivalent to
  /// `yMode == bPred || yMode == splitMv`.
  bool get is4x4 => yMode == bPred || yMode == splitMv;
}

/// Project a 16x16 Y mode to the equivalent 4x4 B-mode that would be used
/// by neighbours of a B_PRED block. Matches `above_block_mode` /
/// `left_block_mode` switch statements in libvpx.
int _macroBlockToBmode(int yMode) {
  switch (yMode) {
    case dcPred:
      return bDcPred;
    case vPred:
      return bVePred;
    case hPred:
      return bHePred;
    case tmPred:
      return bTmPred;
    default:
      return bDcPred;
  }
}

/// Get the B-mode of the 4x4 block above raster-index `b` (0..15) within
/// macroblock at column [mbCol]. [aboveBmodes] is the previous row's last
/// row of B-modes (4 per MB column); for the very top frame row pass an
/// all-zero buffer (decoded as B_DC_PRED -- libvpx returns B_DC_PRED off
/// the top of the frame too).
int _aboveBmode(int b, int mbCol, ModeInfo cur, List<int> aboveBmodes,
    List<int> aboveYModes, bool topRow) {
  if ((b >> 2) == 0) {
    // Top row of this MB: look one MB up.
    if (topRow) return bDcPred;
    final int yModeAbove = aboveYModes[mbCol];
    if (yModeAbove == bPred) {
      // Row 3 of the above MB, column (b & 3).
      return aboveBmodes[mbCol * 4 + (b & 3)];
    }
    return _macroBlockToBmode(yModeAbove);
  }
  return cur.bModes[b - 4];
}

/// Get the B-mode to the left of raster-index `b` within `cur`. [leftMode]
/// is the previous-MB-in-row's [ModeInfo]; pass null for the left edge.
/// [leftBmodes] holds the rightmost column of B-modes of the previous MB
/// (4 entries); only consulted when the left MB was B_PRED.
int _leftBmode(int b, ModeInfo cur, ModeInfo? leftMode, List<int> leftBmodes) {
  if ((b & 3) == 0) {
    // Left edge of this MB.
    if (leftMode == null) return bDcPred;
    if (leftMode.yMode == bPred) {
      // Column 3 of the left MB, row (b >> 2).
      return leftBmodes[b >> 2];
    }
    return _macroBlockToBmode(leftMode.yMode);
  }
  return cur.bModes[b - 1];
}

/// Decode all mode_info entries for a keyframe. Returns an mb_rows x
/// mb_cols list (row-major). Mutates the first partition's boolean
/// decoder in [header].
List<ModeInfo> decodeKeyframeModeInfo(FrameHeader header) {
  if (!header.isKeyFrame) {
    throw StateError('decodeKeyframeModeInfo called on non-keyframe');
  }
  final int mbCols = (header.width + 15) >> 4;
  final int mbRows = (header.height + 15) >> 4;
  final BoolDecoder bc = header.boolDecoder;
  final bool segUpdateMap =
      header.segmentation.enabled && header.segmentation.updateMap;
  final List<int> segTreeProbs = header.segmentation.treeProbs;
  final bool skipFlagInUse = header.mbNoCoeffSkip;
  final int probSkipFalse = header.probSkipFalse;

  final out = List<ModeInfo>.generate(mbRows * mbCols, (_) => ModeInfo(),
      growable: false);

  // Above-row context for B-mode lookups: 4 b-modes per column (row 3 of
  // each MB in the row above us), plus the Y mode of each MB above.
  final Uint8List aboveBmodes = Uint8List(mbCols * 4);
  final Int8List aboveYModes = Int8List(mbCols);

  // Left-column context for B-mode lookups: 4 b-modes from the previous MB
  // in the current row (col 3 of that MB).
  final Uint8List leftBmodes = Uint8List(4);
  ModeInfo? leftMi;

  for (int r = 0; r < mbRows; r++) {
    // Reset left context at the start of each row.
    for (int i = 0; i < 4; i++) {
      leftBmodes[i] = 0;
    }
    leftMi = null;

    for (int c = 0; c < mbCols; c++) {
      final mi = out[r * mbCols + c];

      // Segment id.
      if (segUpdateMap) {
        mi.segmentId = treeDecode(bc, mbFeatureTree, segTreeProbs);
      }

      // Skip-coeff flag.
      if (skipFlagInUse) {
        mi.skipCoeff = bc.read(probSkipFalse) != 0;
      }

      mi.refFrame = 0; // intra

      // Y mode.
      mi.yMode = treeDecode(bc, kfYmodeTree, kfYModeProb);

      if (mi.yMode == bPred) {
        for (int b = 0; b < 16; b++) {
          final int a = _aboveBmode(b, c, mi, aboveBmodes, aboveYModes, r == 0);
          final int l = _leftBmode(b, mi, leftMi, leftBmodes);
          mi.bModes[b] = treeDecode(bc, bmodeTree, kfBmodeProb[a][l]);
        }
      }

      // UV mode.
      mi.uvMode = treeDecode(bc, uvModeTree, kfUvModeProb);

      // Update left context for the next MB in this row.
      if (mi.yMode == bPred) {
        for (int r4 = 0; r4 < 4; r4++) {
          leftBmodes[r4] = mi.bModes[r4 * 4 + 3];
        }
      } else {
        final int v = _macroBlockToBmode(mi.yMode);
        for (int r4 = 0; r4 < 4; r4++) {
          leftBmodes[r4] = v;
        }
      }
      leftMi = mi;
    }

    // After finishing the row, snapshot above context for the next row.
    for (int c = 0; c < mbCols; c++) {
      final mi = out[r * mbCols + c];
      aboveYModes[c] = mi.yMode;
      if (mi.yMode == bPred) {
        for (int k = 0; k < 4; k++) {
          aboveBmodes[c * 4 + k] = mi.bModes[12 + k];
        }
      } else {
        final int v = _macroBlockToBmode(mi.yMode);
        for (int k = 0; k < 4; k++) {
          aboveBmodes[c * 4 + k] = v;
        }
      }
    }
  }

  if (bc.error) {
    throw const FormatException('VP8: bool decoder underran first partition');
  }
  return out;
}

// =========================================================================
// Inter-frame mode/MV decoding (port of vp8/decoder/decodemv.c).
// =========================================================================

/// Sentinel MODE_INFO used as the synthetic "off-frame" neighbour: refFrame
/// = INTRA, mv = 0, yMode = DC. Read-only.
final ModeInfo _offFrameMi = ModeInfo()..refFrame = refIntra;

/// 4-element neighbour count buffer used by find_near_mvs.
/// Indices match libvpx: CNT_INTRA, CNT_NEAREST, CNT_NEAR, CNT_SPLITMV.
const int _cntIntra = 0;
const int _cntNearest = 1;
const int _cntNear = 2;
const int _cntSplitmv = 3;

/// Direct port of `vp8_find_near_mvs` (vp8/common/findnearmv.c). Walks the
/// above/left/aboveleft neighbours of [mi] and populates [nearMvs[0..2]]
/// (best/nearest/near after later post-processing) and [cnt[0..3]]. Returns
/// the candidate index used to seed `best_mv` for SPLITMV/NEWMV.
void _findNearMvs({
  required ModeInfo above,
  required ModeInfo left,
  required ModeInfo aboveLeft,
  required int refFrame,
  required List<bool> signBias,
  required List<Mv> nearMvs,
  required Int32List cnt,
}) {
  for (int i = 0; i < 4; i++) {
    nearMvs[i].row = 0;
    nearMvs[i].col = 0;
    cnt[i] = 0;
  }

  int mvIdx = 0; // points at slot 0 (= "best"); incremented when pushing.

  // -- above --
  if (above.refFrame != refIntra) {
    if (!above.mv.isZero) {
      mvIdx = 1;
      nearMvs[mvIdx].row = above.mv.row;
      nearMvs[mvIdx].col = above.mv.col;
      mvBias(signBias[above.refFrame], signBias[refFrame], nearMvs[mvIdx]);
    }
    cnt[mvIdx == 0 ? _cntIntra : _cntNearest] += 2;
  }

  // -- left --
  if (left.refFrame != refIntra) {
    if (!left.mv.isZero) {
      final t = Mv(left.mv.row, left.mv.col);
      mvBias(signBias[left.refFrame], signBias[refFrame], t);
      if (t.asInt != nearMvs[mvIdx].asInt) {
        mvIdx += 1;
        nearMvs[mvIdx].row = t.row;
        nearMvs[mvIdx].col = t.col;
      }
      cnt[mvIdx == 0
          ? _cntIntra
          : mvIdx == 1
              ? _cntNearest
              : _cntNear] += 2;
    } else {
      cnt[_cntIntra] += 2;
    }
  }

  // -- above-left --
  if (aboveLeft.refFrame != refIntra) {
    if (!aboveLeft.mv.isZero) {
      final t = Mv(aboveLeft.mv.row, aboveLeft.mv.col);
      mvBias(signBias[aboveLeft.refFrame], signBias[refFrame], t);
      if (t.asInt != nearMvs[mvIdx].asInt) {
        mvIdx += 1;
        nearMvs[mvIdx].row = t.row;
        nearMvs[mvIdx].col = t.col;
      }
      cnt[mvIdx == 0
          ? _cntIntra
          : mvIdx == 1
              ? _cntNearest
              : mvIdx == 2
                  ? _cntNear
                  : _cntSplitmv] += 1;
    } else {
      cnt[_cntIntra] += 1;
    }
  }
}

/// Decode mode_info for every MB of an inter frame. Order matches libvpx's
/// `vp8_decode_mode_mvs`; the boolean decoder consumed is the first
/// partition's `bc` (already positioned past the compressed header).
///
/// [refFrameSignBias] is a 4-element list indexed by ref-frame id.
List<ModeInfo> decodeInterFrameModeInfo(
  FrameHeader header,
  List<bool> refFrameSignBias, {
  required int mbCols,
  required int mbRows,
}) {
  if (header.isKeyFrame) {
    throw StateError('decodeInterFrameModeInfo called on key frame');
  }
  final BoolDecoder bc = header.boolDecoder;
  final bool segUpdateMap =
      header.segmentation.enabled && header.segmentation.updateMap;
  final List<int> segTreeProbs = header.segmentation.treeProbs;
  final bool skipFlagInUse = header.mbNoCoeffSkip;
  final int probSkipFalse = header.probSkipFalse;
  final int probIntra = header.probIntra;
  final int probLast = header.probLast;
  final int probGf = header.probGf;
  final Uint8List yModeProb = header.yModeProb;
  final Uint8List uvModeProb = header.uvModeProb;
  final Uint8List bmodeProb = defaultBmodeProb;
  final Uint8List mvc = header.mvContext;

  final out = List<ModeInfo>.generate(mbRows * mbCols, (_) => ModeInfo(),
      growable: false);

  // Scratch buffers for find_near_mvs.
  final List<Mv> nearMvs = <Mv>[Mv(), Mv(), Mv(), Mv()];
  final Int32List cnt = Int32List(4);

  for (int r = 0; r < mbRows; r++) {
    // Per-row MV-clamp edges in 1/8-pel.
    final int mbToTopEdge = -((r * 16) << 3) - mvMarginEdge;
    final int mbToBottomEdge = (((mbRows - 1 - r) * 16) << 3) + mvMarginEdge;

    for (int c = 0; c < mbCols; c++) {
      final mi = out[r * mbCols + c];

      // Segment id.
      if (segUpdateMap) {
        // libvpx: 2 reads against treeProbs[0] then [1] or [2].
        if (bc.read(segTreeProbs[0]) != 0) {
          mi.segmentId = 2 + bc.read(segTreeProbs[2]);
        } else {
          mi.segmentId = bc.read(segTreeProbs[1]);
        }
      }

      if (skipFlagInUse) {
        mi.skipCoeff = bc.read(probSkipFalse) != 0;
      }

      // Intra vs inter.
      final bool isInter = bc.read(probIntra) != 0;
      if (!isInter) {
        // Intra MB inside an inter frame.
        mi.refFrame = refIntra;
        mi.yMode = treeDecode(bc, ymodeTree, yModeProb);
        if (mi.yMode == bPred) {
          for (int b = 0; b < 16; b++) {
            mi.bModes[b] = treeDecode(bc, bmodeTree, bmodeProb);
          }
        }
        mi.uvMode = treeDecode(bc, uvModeTree, uvModeProb);
        // Inter fields default-zero already.
        continue;
      }

      // -- Inter MB --
      // Ref frame.
      if (bc.read(probLast) != 0) {
        mi.refFrame = 2 + bc.read(probGf); // GOLDEN or ALTREF
      } else {
        mi.refFrame = refLast;
      }

      // Pull neighbour MIs (synthetic INTRA when off-frame).
      final ModeInfo above = r > 0 ? out[(r - 1) * mbCols + c] : _offFrameMi;
      final ModeInfo left = c > 0 ? out[r * mbCols + (c - 1)] : _offFrameMi;
      final ModeInfo aboveLeft =
          (r > 0 && c > 0) ? out[(r - 1) * mbCols + (c - 1)] : _offFrameMi;

      _findNearMvs(
        above: above,
        left: left,
        aboveLeft: aboveLeft,
        refFrame: mi.refFrame,
        signBias: refFrameSignBias,
        nearMvs: nearMvs,
        cnt: cnt,
      );

      // Per-row MV-clamp edges in 1/8-pel.
      final int mbToLeftEdge = -((c * 16) << 3) - mvMarginEdge;
      final int mbToRightEdge = (((mbCols - 1 - c) * 16) << 3) + mvMarginEdge;

      // Mode tree: vp8_mv_ref_tree, gated by vp8_mode_contexts.
      if (bc.read(vp8ModeContexts[cnt[_cntIntra]][0]) != 0) {
        // Merge near-NEAREST tie-breaker as in libvpx.
        if ((cnt[_cntSplitmv] > 0) &&
            (nearMvs[3].asInt == nearMvs[_cntNearest].asInt)) {
          cnt[_cntNearest] += 1;
        }
        // Swap near/nearest if near has higher count.
        if (cnt[_cntNear] > cnt[_cntNearest]) {
          final int tc = cnt[_cntNearest];
          cnt[_cntNearest] = cnt[_cntNear];
          cnt[_cntNear] = tc;
          final int tr = nearMvs[_cntNearest].row;
          final int tco = nearMvs[_cntNearest].col;
          nearMvs[_cntNearest].row = nearMvs[_cntNear].row;
          nearMvs[_cntNearest].col = nearMvs[_cntNear].col;
          nearMvs[_cntNear].row = tr;
          nearMvs[_cntNear].col = tco;
        }

        if (bc.read(vp8ModeContexts[cnt[_cntNearest]][1]) != 0) {
          if (bc.read(vp8ModeContexts[cnt[_cntNear]][2]) != 0) {
            // NEWMV or SPLITMV.
            // "best" candidate index: CNT_INTRA + (NEAREST_cnt >= INTRA_cnt).
            final int nearIndex =
                _cntIntra + (cnt[_cntNearest] >= cnt[_cntIntra] ? 1 : 0);
            clampMv2(nearMvs[nearIndex], mbToLeftEdge, mbToRightEdge,
                mbToTopEdge, mbToBottomEdge);

            // Recompute CNT_SPLITMV from neighbour modes.
            cnt[_cntSplitmv] = ((above.yMode == splitMv ? 1 : 0) +
                        (left.yMode == splitMv ? 1 : 0)) *
                    2 +
                (aboveLeft.yMode == splitMv ? 1 : 0);

            if (bc.read(vp8ModeContexts[cnt[_cntSplitmv]][3]) != 0) {
              // SPLITMV.
              mi.yMode = splitMv;
              _decodeSplitMv(
                bc: bc,
                mi: mi,
                left: left,
                above: above,
                bestMv: nearMvs[nearIndex],
                mvc: mvc,
                mbToLeftEdge: mbToLeftEdge,
                mbToRightEdge: mbToRightEdge,
                mbToTopEdge: mbToTopEdge,
                mbToBottomEdge: mbToBottomEdge,
              );
              // mbmi.mv = bMvs[15]
              final int packed15 = mi.bMvs[15];
              mi.mv.row = unpackBMvRow(packed15);
              mi.mv.col = unpackBMvCol(packed15);
            } else {
              // NEWMV.
              mi.yMode = newMv;
              final delta = readMv(bc, mvc);
              mi.mv.row = delta.row + nearMvs[nearIndex].row;
              mi.mv.col = delta.col + nearMvs[nearIndex].col;
              _fillBMvsFromMb(mi);
            }
          } else {
            mi.yMode = nearMv;
            mi.mv.row = nearMvs[_cntNear].row;
            mi.mv.col = nearMvs[_cntNear].col;
            clampMv2(mi.mv, mbToLeftEdge, mbToRightEdge, mbToTopEdge,
                mbToBottomEdge);
            _fillBMvsFromMb(mi);
          }
        } else {
          mi.yMode = nearestMv;
          mi.mv.row = nearMvs[_cntNearest].row;
          mi.mv.col = nearMvs[_cntNearest].col;
          clampMv2(
              mi.mv, mbToLeftEdge, mbToRightEdge, mbToTopEdge, mbToBottomEdge);
          _fillBMvsFromMb(mi);
        }
      } else {
        mi.yMode = zeroMv;
        mi.mv.row = 0;
        mi.mv.col = 0;
        _fillBMvsFromMb(mi);
      }
    }
  }

  if (bc.error) {
    throw const FormatException('VP8: bool decoder underran first partition');
  }
  return out;
}

void _fillBMvsFromMb(ModeInfo mi) {
  final int packed = ((mi.mv.row & 0xffff) << 16) | (mi.mv.col & 0xffff);
  for (int i = 0; i < 16; i++) {
    mi.bMvs[i] = packed;
  }
}

void _decodeSplitMv({
  required BoolDecoder bc,
  required ModeInfo mi,
  required ModeInfo left,
  required ModeInfo above,
  required Mv bestMv,
  required Uint8List mvc,
  required int mbToLeftEdge,
  required int mbToRightEdge,
  required int mbToTopEdge,
  required int mbToBottomEdge,
}) {
  // Split configuration: 0 = 16x8, 1 = 8x16, 2 = 8x8, 3 = 4x4.
  int s = 3;
  int numP = 16;
  if (bc.read(110) != 0) {
    s = 2;
    numP = 4;
    if (bc.read(111) != 0) {
      s = bc.read(150);
      numP = 2;
    }
  }
  mi.partitioning = s;

  for (int j = 0; j < numP; j++) {
    final int k = vp8MbSplitOffset[s][j];

    // Left neighbour for this subset.
    int leftMvPacked;
    if ((k & 3) == 0) {
      if (left.yMode != splitMv) {
        leftMvPacked = ((left.mv.row & 0xffff) << 16) | (left.mv.col & 0xffff);
      } else {
        // Block (k + 3) of left MB.
        leftMvPacked = left.bMvs[k + 4 - 1];
      }
    } else {
      leftMvPacked = mi.bMvs[k - 1];
    }

    // Above neighbour for this subset.
    int aboveMvPacked;
    if ((k >> 2) == 0) {
      if (above.yMode != splitMv) {
        aboveMvPacked =
            ((above.mv.row & 0xffff) << 16) | (above.mv.col & 0xffff);
      } else {
        aboveMvPacked = above.bMvs[k + 16 - 4];
      }
    } else {
      aboveMvPacked = mi.bMvs[k - 4];
    }

    final int lez = leftMvPacked == 0 ? 1 : 0;
    final int aez = aboveMvPacked == 0 ? 1 : 0;
    final int lea = leftMvPacked == aboveMvPacked ? 1 : 0;
    final probs = vp8SubMvRefProb3[(aez << 2) | (lez << 1) | lea];

    int blockPacked;
    if (bc.read(probs[0]) != 0) {
      if (bc.read(probs[1]) != 0) {
        if (bc.read(probs[2]) != 0) {
          // NEW4X4: read MV component pair and add to bestMv.
          final int row = readMvComponent(bc, mvc, 0) * 2 + bestMv.row;
          final int col = readMvComponent(bc, mvc, mvpCount) * 2 + bestMv.col;
          // Note: per-block MV is NOT clamped (matches libvpx's
          // need_to_clamp_mvs flag which only sets a check bit).
          blockPacked = ((row & 0xffff) << 16) | (col & 0xffff);
        } else {
          // ZERO4X4.
          blockPacked = 0;
        }
      } else {
        // ABOVE4X4.
        blockPacked = aboveMvPacked;
      }
    } else {
      // LEFT4X4.
      blockPacked = leftMvPacked;
    }

    // Fill all 4x4 blocks in this subset.
    final fillCount = mbsplitFillCount[s];
    final fillBase = j * fillCount;
    for (int f = 0; f < fillCount; f++) {
      mi.bMvs[mbsplitFillOffset[s][fillBase + f]] = blockPacked;
    }
  }
}
