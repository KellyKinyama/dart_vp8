// Top-level VP8 decoder.
//
// Supports key frames and inter frames including SPLITMV. Reference-
// frame management, inter-prediction wiring and mode-delta loop-filter
// handling all live here.

import 'dart:io';
import 'dart:typed_data';

import 'bool_decoder.dart';
import 'entropy.dart';
import 'frame_header.dart';
import 'intra_pred.dart';
import 'ivf_reader.dart';
import 'loop_filter.dart';
import 'mode_info.dart';
import 'mv.dart';
import 'quant.dart';
import 'recon.dart';
import 'ref_frame.dart';

/// Public decoded frame. The Y/U/V planes are tightly packed at the
/// macroblock-aligned stride; callers can use [yStride] / [uvStride] to
/// walk rows, and [width]/[height] to crop.
class DecodedFrame {
  DecodedFrame({
    required this.width,
    required this.height,
    required this.yStride,
    required this.uvStride,
    required this.y,
    required this.u,
    required this.v,
    required this.isKeyFrame,
  });

  final int width;
  final int height;
  final int yStride;
  final int uvStride;
  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final bool isKeyFrame;
}

/// VP8 decoder. A single instance can decode a stream of frames in order;
/// internal state (reference buffers, loop-filter LUTs) is reused across
/// calls.
class Vp8Decoder {
  int _width = 0;
  int _height = 0;
  int _mbCols = 0;
  int _mbRows = 0;
  int _yStride = 0;
  int _uvStride = 0;
  Uint8List _y = Uint8List(0);
  Uint8List _u = Uint8List(0);
  Uint8List _v = Uint8List(0);

  // Reference frames (padded with replicated borders).
  RefFrame? _refLast;
  RefFrame? _refGolden;
  RefFrame? _refAltref;

  // Sign-bias indexed by ref-frame id (INTRA, LAST, GOLDEN, ALTREF).
  // LAST and INTRA always have sign-bias 0; GOLDEN/ALTREF come from header.
  final List<bool> _refSignBias = <bool>[false, false, false, false];

  LoopFilterLut? _lfLut;
  int _lfSharpness = -1;

  // Persistent entropy state (coef probs, mode probs, MV context). Reset
  // to defaults on every keyframe; otherwise updated by inter frames
  // whose `refresh_entropy_probs` flag is set.
  final EntropyState _entropy = EntropyState();

  /// Diagnostic: when true, skip the loop filter pass entirely.
  bool debugSkipLoopFilter = false;

  /// Diagnostic: invoked once per MB AFTER token decode but BEFORE
  /// reconstruction. `globalMbIdx` increments monotonically across frames
  /// to match libvpx's per-MB counter.
  void Function(int globalMbIdx, Int16List qcoeff, Uint8List eobs, ModeInfo mb,
      DequantSet dq)? debugPerMbHook;
  int _globalMbIdx = 0;
  int _frameCounter = 0;

  /// The per-MB ModeInfo list from the most recently decoded frame, in
  /// row-major raster order. Length = `_mbCols * _mbRows`. Exposed for
  /// diagnostic tooling; the list is overwritten on the next [decode].
  List<ModeInfo> get debugLastModeInfo => _debugMi ?? const <ModeInfo>[];
  List<ModeInfo>? _debugMi;

  /// Macroblock columns / rows of the currently-allocated buffers.
  int get debugMbCols => _mbCols;
  int get debugMbRows => _mbRows;

  /// Filter level used for an MB in the last frame (post mode/ref deltas).
  int debugFilterLevel(int mbIdx) => _debugFilterLevel?[mbIdx] ?? 0;
  Int32List? _debugFilterLevel;

  /// Diagnostic: the current refLast buffer (or null).
  RefFrame? get debugRefLast => _refLast;

  /// Decode one IVF frame (a complete VP8 frame payload). Returns the
  /// reconstructed frame; the returned buffers are aliased with the
  /// decoder's internal state and will be overwritten by the next call to
  /// [decode].
  DecodedFrame decode(IvfFrame frame) {
    final Uint8List data = frame.data;
    final FrameHeader header = parseFrameHeader(data, priorState: _entropy);

    // On a keyframe always (re-)allocate buffers; an inter frame must
    // already have refs in place.
    if (header.isKeyFrame) {
      _width = header.width;
      _height = header.height;
      _mbCols = (_width + 15) >> 4;
      _mbRows = (_height + 15) >> 4;
      _yStride = _mbCols * 16;
      _uvStride = _mbCols * 8;
      _y = Uint8List(_yStride * _mbRows * 16);
      _u = Uint8List(_uvStride * _mbRows * 8);
      _v = Uint8List(_uvStride * _mbRows * 8);
    } else {
      if (_refLast == null) {
        throw const FormatException(
            'VP8: inter frame before any keyframe; no LAST reference');
      }
      // Inter-frame output reuses the previous-frame allocation (same dims).
    }

    // Sign-bias snapshot for this frame (used by find_near_mvs).
    _refSignBias[refIntra] = false;
    _refSignBias[refLast] = false;
    _refSignBias[refGolden] = header.signBiasGolden;
    _refSignBias[refAltref] = header.signBiasAltref;

    // Phase 1: decode mode_info entries (first partition).
    final List<ModeInfo> mi = header.isKeyFrame
        ? decodeKeyframeModeInfo(header)
        : decodeInterFrameModeInfo(header, _refSignBias,
            mbCols: _mbCols, mbRows: _mbRows);
    _debugMi = mi;
    _debugFilterLevel = Int32List(mi.length);

    // Phase 2: open the residual (token) partitions. For numParts > 1,
    // the first partition is preceded by (numParts-1) 3-byte little-endian
    // size entries; the last partition's size is implicit.
    final int numParts = 1 << header.log2NumDctPartitions;
    final List<BoolDecoder> tokBcs =
        _setupTokenDecoders(data, header.residualPartitionsOffset, numParts);

    // Phase 3: per-MB token decode + reconstruction.
    final Uint8List coefProbs = header.coefProbs;
    final Int16List qcoeff = Int16List(blocksPerMb * blockSize);
    final Uint8List eobs = Uint8List(blocksPerMb);
    final EntropyContext eCtx = EntropyContext();

    // One entropy "above" context per MB column for the four Y / two U /
    // two V / one Y2 planes (9 entries per column).
    final AboveContextRow aboveRow = AboveContextRow(_mbCols);

    final DequantSet baseDq = buildDequant(
      qi: header.quantizer.yAcQi,
      y1DcDelta: header.quantizer.y1DcDelta,
      y2DcDelta: header.quantizer.y2DcDelta,
      y2AcDelta: header.quantizer.y2AcDelta,
      uvDcDelta: header.quantizer.uvDcDelta,
      uvAcDelta: header.quantizer.uvAcDelta,
    );
    final List<DequantSet> segDq = _buildPerSegmentDequant(header, baseDq);

    for (int r = 0; r < _mbRows; r++) {
      // Pick the boolean decoder for this MB row (round-robin across
      // residual partitions).
      final BoolDecoder tokBc = tokBcs[r % numParts];
      // Reset left context at the start of each row.
      for (int i = 0; i < 9; i++) {
        eCtx.left[i] = 0;
      }
      for (int c = 0; c < _mbCols; c++) {
        final mb = mi[r * _mbCols + c];

        // Copy this column's above context in.
        final Uint8List ab = aboveRow.sliceFor(c);
        for (int i = 0; i < 9; i++) {
          eCtx.above[i] = ab[i];
        }

        // Reset coefficients/eobs for this MB.
        for (int i = 0; i < qcoeff.length; i++) {
          qcoeff[i] = 0;
        }
        for (int i = 0; i < eobs.length; i++) {
          eobs[i] = 0;
        }

        if (mb.skipCoeff) {
          mb.eobMax = 0;
          // No residual at all. Context bookkeeping for skipped MBs:
          // 16 Y blocks (or Y2 if !is4x4) all reset to 0 in above/left.
          if (mb.is4x4) {
            for (int k = 0; k < 4; k++) {
              eCtx.above[k] = 0;
              eCtx.left[k] = 0;
            }
          } else {
            for (int k = 0; k < 4; k++) {
              eCtx.above[k] = 0;
              eCtx.left[k] = 0;
            }
            eCtx.above[8] = 0;
            eCtx.left[8] = 0;
          }
          for (int k = 4; k < 8; k++) {
            eCtx.above[k] = 0;
            eCtx.left[k] = 0;
          }
        } else {
          final int eobTotal = decodeMbTokens(
            bc: tokBc,
            coefProbs: coefProbs,
            is4x4: mb.is4x4,
            context: eCtx,
            qcoeff: qcoeff,
            eobs: eobs,
          );
          // Record the maximum eob across all blocks of this MB. Y2 is
          // at index 24 only when !is4x4 (the MB uses the 2nd-stage WHT).
          int m = 0;
          final int last = mb.is4x4 ? 24 : 25;
          for (int i = 0; i < last; i++) {
            if (eobs[i] > m) m = eobs[i];
          }
          mb.eobMax = m;
          // libvpx: when token decode yields no real coefficients on a
          // non-B_PRED / non-SPLITMV MB, force mb_skip_coeff=1 so the
          // loop filter treats it as skipped (suppresses inner-edge LF).
          // The check uses eob_total (which accounts for skip_dc on Y AC
          // blocks), not max(eobs).
          if (eobTotal == 0 && !mb.is4x4) {
            mb.skipCoeff = true;
          }
        }

        // Save updated above context back to the row.
        for (int i = 0; i < 9; i++) {
          ab[i] = eCtx.above[i];
        }

        final DequantSet dq = segDq[mb.segmentId];

        final hook = debugPerMbHook;
        if (hook != null) hook(_globalMbIdx, qcoeff, eobs, mb, dq);
        _globalMbIdx++;

        if (mb.refFrame == refIntra) {
          reconstructMb(
            mi: mb,
            qcoeff: qcoeff,
            eobs: eobs,
            dq: dq,
            yPlane: _y,
            uPlane: _u,
            vPlane: _v,
            mbCol: c,
            mbRow: r,
            mbCols: _mbCols,
            yStride: _yStride,
            uvStride: _uvStride,
          );
        } else {
          final RefFrame? ref = _refFor(mb.refFrame);
          if (ref == null) {
            throw FormatException(
                'VP8: inter MB references missing frame ${mb.refFrame}');
          }
          reconstructMbInter(
            mi: mb,
            qcoeff: qcoeff,
            eobs: eobs,
            dq: dq,
            ref: ref,
            yPlane: _y,
            uPlane: _u,
            vPlane: _v,
            mbCol: c,
            mbRow: r,
            yStride: _yStride,
            uvStride: _uvStride,
            useBilinear: header.version != 0,
          );
        }
      }
    }

    // Phase 4: loop filter pass.
    if (!debugSkipLoopFilter) {
      _runLoopFilter(header, mi);
    }

    // Phase 5: refresh reference buffers per header flags.
    _updateReferenceBuffers(header);

    // Phase 6: commit / discard entropy updates.
    //   * Keyframe: the in-header probs are parsed starting from VP8
    //     defaults and become the new persistent state.
    //   * Inter frame with `refresh_entropy_probs`: commit the (possibly
    //     updated) frame-local probs to the persistent state.
    //   * Inter frame without it: discard the local probs (the persistent
    //     state remains untouched, so no action needed).
    if (header.isKeyFrame || header.refreshEntropyProbs) {
      _entropy.commitFrom(header);
    } else {
      // LF deltas always persist across frames (libvpx semantics).
      _entropy.commitLfFrom(header);
    }

    _frameCounter++;

    return DecodedFrame(
      width: _width,
      height: _height,
      yStride: _yStride,
      uvStride: _uvStride,
      y: _y,
      u: _u,
      v: _v,
      isKeyFrame: header.isKeyFrame,
    );
  }

  // ---- Helpers --------------------------------------------------------------

  RefFrame? _refFor(int refFrame) {
    switch (refFrame) {
      case refLast:
        return _refLast;
      case refGolden:
        return _refGolden;
      case refAltref:
        return _refAltref;
      default:
        return null;
    }
  }

  /// Snapshot the just-decoded frame into reference buffers per header
  /// refresh / copy flags. Matches `vp8_swap_yv12_buffer` semantics in
  /// libvpx (`yv12extend.c` + `decodeframe.c` post-decode loop).
  void _updateReferenceBuffers(FrameHeader header) {
    // The newly-decoded frame becomes the new LAST (always, on keyframes;
    // gated by `refreshLastFrame` on inter frames).
    RefFrame? newGolden = _refGolden;
    RefFrame? newAltref = _refAltref;

    // Apply copy_buffer_to_gf / copy_buffer_to_arf BEFORE the new last
    // overwrites the previous one, matching libvpx ordering.
    if (!header.isKeyFrame) {
      switch (header.copyBufferToGf) {
        case 0:
          break;
        case 1:
          newGolden = _refLast == null ? null : cloneRefFrame(_refLast!);
        case 2:
          newGolden = _refAltref == null ? null : cloneRefFrame(_refAltref!);
      }
      switch (header.copyBufferToArf) {
        case 0:
          break;
        case 1:
          newAltref = _refLast == null ? null : cloneRefFrame(_refLast!);
        case 2:
          newAltref = _refGolden == null ? null : cloneRefFrame(_refGolden!);
      }
    }

    // Build a RefFrame from the just-decoded planes (border-padded).
    if (header.refreshLastFrame ||
        header.refreshGoldenFrame ||
        header.refreshAltrefFrame) {
      final fresh = RefFrame(width: _width, height: _height);
      refFrameFromPlanes(
        dst: fresh,
        srcY: _y,
        srcYStride: _yStride,
        srcU: _u,
        srcV: _v,
        srcUvStride: _uvStride,
      );
      if (header.refreshLastFrame) _refLast = fresh;
      if (header.refreshGoldenFrame) {
        newGolden = header.refreshLastFrame ? cloneRefFrame(fresh) : fresh;
      }
      if (header.refreshAltrefFrame) {
        newAltref = (header.refreshLastFrame || header.refreshGoldenFrame)
            ? cloneRefFrame(fresh)
            : fresh;
      }
    }

    _refGolden = newGolden;
    _refAltref = newAltref;
  }

  /// Parse the partition-size table (if any) and return one [BoolDecoder]
  /// per residual partition. For `numParts > 1`, the table contains
  /// `numParts - 1` 3-byte little-endian sizes at [sizeTableOff]; the last
  /// partition's size is implicit (extends to end of frame).
  List<BoolDecoder> _setupTokenDecoders(
      Uint8List frame, int sizeTableOff, int numParts) {
    if (numParts < 1 || numParts > 8) {
      throw FormatException('VP8: invalid token partition count $numParts');
    }
    int off = sizeTableOff + 3 * (numParts - 1);
    final out = <BoolDecoder>[];
    for (int i = 0; i < numParts; i++) {
      int size;
      if (i < numParts - 1) {
        final int p = sizeTableOff + i * 3;
        if (p + 3 > frame.length) {
          throw const FormatException(
              'VP8: truncated token-partition size table');
        }
        size = frame[p] | (frame[p + 1] << 8) | (frame[p + 2] << 16);
        if (off + size > frame.length) {
          throw FormatException(
              'VP8: token partition $i runs past end of frame');
        }
      } else {
        size = frame.length - off;
      }
      out.add(BoolDecoder(Uint8List.sublistView(frame, off, off + size)));
      off += size;
    }
    return out;
  }

  List<DequantSet> _buildPerSegmentDequant(
      FrameHeader header, DequantSet base) {
    final out = List<DequantSet>.filled(maxMbSegments, base);
    if (!header.segmentation.enabled) return out;
    final Int8List qData = header.segmentation.featureData[MbLvl.altQ];
    final bool absDelta = header.segmentation.absDelta;
    for (int s = 0; s < maxMbSegments; s++) {
      final int qi =
          absDelta ? qData[s] & 0x7f : (header.quantizer.yAcQi + qData[s]);
      out[s] = buildDequant(
        qi: qi.clamp(0, 127),
        y1DcDelta: header.quantizer.y1DcDelta,
        y2DcDelta: header.quantizer.y2DcDelta,
        y2AcDelta: header.quantizer.y2AcDelta,
        uvDcDelta: header.quantizer.uvDcDelta,
        uvAcDelta: header.quantizer.uvAcDelta,
      );
    }
    return out;
  }

  void _runLoopFilter(FrameHeader header, List<ModeInfo> mi) {
    final LoopFilter lf = header.loopFilter;
    if (lf.level == 0) return;
    if (_lfLut == null || _lfSharpness != lf.sharpness) {
      _lfLut = LoopFilterLut.forSharpness(lf.sharpness);
      _lfSharpness = lf.sharpness;
    }
    final LoopFilterLut lut = _lfLut!;
    final int frameType = header.isKeyFrame ? frameKey : frameInter;
    final bool simple = lf.type != 0;

    // Debug: dump LF stages for one (frame_idx, mb_row, mb_col).
    final dbg = Platform.environment['VPX_DUMP_LF_MB'] ?? '';
    int? dbgFrame, dbgRow, dbgCol;
    if (dbg.isNotEmpty) {
      final parts = dbg.split(',');
      if (parts.length == 3) {
        dbgFrame = int.parse(parts[0]);
        dbgRow = int.parse(parts[1]);
        dbgCol = int.parse(parts[2]);
      }
    }
    void _dumpY(String label, int r, int c) {
      final yOff = r * 16 * _yStride + c * 16;
      stderr.writeln('LF mb=($r,$c) $label:');
      for (int rr = 0; rr < 16; rr++) {
        final row = <int>[];
        for (int cc = 0; cc < 16; cc++) {
          row.add(_y[yOff + rr * _yStride + cc]);
        }
        stderr.writeln('  r${rr.toString().padLeft(2)}: ${row.join(' ')}');
      }
    }

    for (int r = 0; r < _mbRows; r++) {
      for (int c = 0; c < _mbCols; c++) {
        final mb = mi[r * _mbCols + c];
        final int level = _filterLevelFor(lf, mb, header);
        _debugFilterLevel![r * _mbCols + c] = level;
        if (level == 0) continue;
        final LoopFilterInfo info = lut.infoFor(frameType, level);

        final int yOff = r * 16 * _yStride + c * 16;
        final int uvOff = r * 8 * _uvStride + c * 8;

        final bool dump =
            dbgFrame == _frameCounter && dbgRow == r && dbgCol == c;
        if (dump) {
          stderr.writeln(
              'LF mb=($r,$c) fl=$level mblim=${info.mblim} blim=${info.blim} lim=${info.lim} hev=${info.hevThr} BEFORE:');
          _dumpY('BEFORE', r, c);
        }

        if (simple) {
          if (c > 0) {
            loopFilterSimpleVerticalEdge(_y, yOff, _yStride, info.mblim);
          }
          // libvpx order: Mbv, Bv, Mbh, Bh.
          if (mb.is4x4 || !mb.skipCoeff) {
            loopFilterBvs(_y, yOff, _yStride, info.blim);
          }
          if (dump) _dumpY('AFTER V-pass', r, c);
          if (r > 0) {
            loopFilterSimpleHorizontalEdge(_y, yOff, _yStride, info.mblim);
          }
          if (mb.is4x4 || !mb.skipCoeff) {
            loopFilterBhs(_y, yOff, _yStride, info.blim);
          }
          if (dump) _dumpY('AFTER H-pass', r, c);
        } else {
          if (c > 0) {
            loopFilterMbv(
                _y, yOff, _yStride, _u, uvOff, _v, uvOff, _uvStride, info);
          }
          if (mb.is4x4 || !mb.skipCoeff) {
            loopFilterBv(
                _y, yOff, _yStride, _u, uvOff, _v, uvOff, _uvStride, info);
          }
          if (dump) _dumpY('AFTER V-pass', r, c);
          if (r > 0) {
            loopFilterMbh(
                _y, yOff, _yStride, _u, uvOff, _v, uvOff, _uvStride, info);
          }
          if (mb.is4x4 || !mb.skipCoeff) {
            loopFilterBh(
                _y, yOff, _yStride, _u, uvOff, _v, uvOff, _uvStride, info);
          }
          if (dump) _dumpY('AFTER H-pass', r, c);
        }
      }
    }
  }

  int _filterLevelFor(LoopFilter lf, ModeInfo mb, FrameHeader header) {
    int level = lf.level;
    final seg = header.segmentation;
    if (seg.enabled) {
      final int s = seg.featureData[MbLvl.altLf][mb.segmentId];
      level = seg.absDelta ? s : level + s;
    }
    if (lf.modeRefDeltaEnabled) {
      // ref-frame delta.
      level += lf.refDeltas[mb.refFrame];
      // mode-LF index: 0 for INTRA-B_PRED, 1 for ZEROMV, 3 for SPLITMV,
      // 2 for any other inter mode. Pure intra DC/V/H/TM contribute zero.
      if (mb.refFrame == refIntra) {
        if (mb.yMode == bPred) level += lf.modeDeltas[0];
      } else if (mb.yMode == zeroMv) {
        level += lf.modeDeltas[1];
      } else if (mb.yMode == splitMv) {
        level += lf.modeDeltas[3];
      } else {
        level += lf.modeDeltas[2];
      }
    }
    if (level < 0) return 0;
    if (level > maxLoopFilter) return maxLoopFilter;
    return level;
  }
}
