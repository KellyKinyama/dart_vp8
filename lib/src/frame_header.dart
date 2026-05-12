// VP8 frame-header parsing.
//
// Implements RFC 6386 §9 and matches libvpx's `vp8_decode_frame` parsing
// pipeline up to (and including) the first chunk of per-MB context probs
// that libvpx happens to read at the start of `mb_mode_mv_init`. Those
// bytes (mb_no_coeff_skip, prob_skip_false, prob_intra/last/gf, the y/uv
// mode-prob updates and the mv-prob updates) are still part of the
// pre-residual header, so they live here.
//
// All probability tables that are *updated* per frame are returned as
// Uint8List copies; the defaults are deep-copied so the caller's tables
// aren't mutated.

import 'dart:typed_data';

import 'bool_decoder.dart';
import 'constants/coef_probs.dart';
import 'constants/mode_mv_probs.dart';

/// Per-segment feature kinds, in libvpx index order.
class MbLvl {
  static const int altQ = 0; // alternative quantizer
  static const int altLf = 1; // alternative loop-filter level
  static const int max = 2;
}

/// Number of macroblock-level segments.
const int maxMbSegments = 4;

/// Probabilities used by the segment-ID tree (3 internal nodes).
const int mbFeatureTreeProbs = 3;

/// Per-feature bitstream widths for segment data, matching
/// `vp8_mb_feature_data_bits` in libvpx.
const List<int> _mbFeatureDataBits = <int>[7, 6];

/// Max ref-frame and per-mode loop-filter delta entries.
const int maxRefLfDeltas = 4;
const int maxModeLfDeltas = 4;

/// Segmentation parameters from the frame header.
class Segmentation {
  bool enabled = false;
  bool updateMap = false;
  bool updateData = false;

  /// 0 = deltas applied to the base quantizer; 1 = data is absolute.
  bool absDelta = false;

  /// Per-feature, per-segment data. `[feature][segment]`.
  /// Feature 0 = quantizer, feature 1 = loop-filter level.
  final List<Int8List> featureData = <Int8List>[
    Int8List(maxMbSegments),
    Int8List(maxMbSegments),
  ];

  /// Probabilities used to decode the 2-bit segment ID per MB.
  final Uint8List treeProbs = Uint8List.fromList(<int>[255, 255, 255]);
}

/// Loop-filter parameters from the frame header.
class LoopFilter {
  /// 0 = normal, 1 = simple.
  int type = 0;

  /// 0..63.
  int level = 0;

  /// 0..7.
  int sharpness = 0;

  bool modeRefDeltaEnabled = false;
  bool modeRefDeltaUpdate = false;

  final Int8List refDeltas = Int8List(maxRefLfDeltas);
  final Int8List modeDeltas = Int8List(maxModeLfDeltas);
}

/// Quantizer indices from the frame header.
class QuantizerIndices {
  /// Base quantizer (7 bits, 0..127).
  int yAcQi = 0;

  /// Signed deltas, each 4 bits + sign.
  int y1DcDelta = 0;
  int y2DcDelta = 0;
  int y2AcDelta = 0;
  int uvDcDelta = 0;
  int uvAcDelta = 0;
}

/// Parsed VP8 frame header. The returned [boolDecoder] is positioned to
/// produce the very next bit consumed by mode/MV decoding (Stage 4+).
class FrameHeader {
  FrameHeader._();

  // --- Uncompressed header -------------------------------------------------
  late bool isKeyFrame;
  late int version; // 0..7
  late bool showFrame;
  late int firstPartitionSize; // bytes

  // Keyframe-only fields.
  int width = 0;
  int height = 0;
  int horizScale = 0;
  int vertScale = 0;
  int colorSpace = 0; // keyframe, 1 bit
  int clampingType = 0; // keyframe, 1 bit

  // --- Compressed header ---------------------------------------------------
  final Segmentation segmentation = Segmentation();
  final LoopFilter loopFilter = LoopFilter();

  /// log2 of the number of DCT residual partitions: 0, 1, 2 or 3
  /// (=> 1, 2, 4 or 8 partitions).
  int log2NumDctPartitions = 0;

  final QuantizerIndices quantizer = QuantizerIndices();

  // Non-keyframe ref-management.
  bool refreshGoldenFrame = false;
  bool refreshAltrefFrame = false;
  int copyBufferToGf = 0; // 0..2
  int copyBufferToArf = 0; // 0..2
  bool signBiasGolden = false;
  bool signBiasAltref = false;

  bool refreshEntropyProbs = false;
  bool refreshLastFrame = false;

  /// Possibly-updated token (coefficient) probabilities, 1056 bytes.
  /// Indexed via [coefProbIndex].
  late Uint8List coefProbs;

  bool mbNoCoeffSkip = false;
  int probSkipFalse = 0;

  // Non-keyframe ref-pred / mode-prob fields.
  int probIntra = 0;
  int probLast = 0;
  int probGf = 0;
  late Uint8List yModeProb; // 4
  late Uint8List uvModeProb; // 3
  late Uint8List mvContext; // 2 * 19

  /// Offset, in the original frame buffer, of the first byte after the
  /// first (control) partition. This is where the partition-size table for
  /// the residual partitions starts.
  late int residualPartitionsOffset;

  /// Boolean decoder positioned at the next bit of the first partition,
  /// to be reused by Stage 4 (MB mode/MV parsing).
  late BoolDecoder boolDecoder;
}

/// Read a signed delta-Q field: `flag (1 bit), if set: magnitude (4 bits),
/// sign (1 bit)`. Matches libvpx's `get_delta_q`.
int _readDeltaQ(BoolDecoder bc) {
  if (bc.read(128) == 0) return 0;
  final int mag = bc.readLiteral(4);
  final int sign = bc.read(128);
  return sign != 0 ? -mag : mag;
}

/// Persistent VP8 entropy state. The decoder maintains one of these
/// across frames and seeds [parseFrameHeader] with it; on success it
/// either commits the updates from the frame (if `refresh_entropy_probs`
/// is set, or after a keyframe) or discards them.
class EntropyState {
  EntropyState()
      : coefProbs = Uint8List.fromList(defaultCoefProbs),
        yModeProb = Uint8List.fromList(defaultYModeProb),
        uvModeProb = Uint8List.fromList(defaultUvModeProb),
        mvContext = Uint8List.fromList(defaultMvContext),
        lfRefDeltas = Int8List(maxRefLfDeltas),
        lfModeDeltas = Int8List(maxModeLfDeltas);

  final Uint8List coefProbs;
  final Uint8List yModeProb;
  final Uint8List uvModeProb;
  final Uint8List mvContext;
  // Persistent LF mode/ref deltas (carried across frames; updated only
  // when a frame's mode_ref_lf_delta_update flag is set).
  final Int8List lfRefDeltas;
  final Int8List lfModeDeltas;

  /// Reset to VP8 defaults (used at keyframes).
  void resetToDefaults() {
    coefProbs.setAll(0, defaultCoefProbs);
    yModeProb.setAll(0, defaultYModeProb);
    uvModeProb.setAll(0, defaultUvModeProb);
    mvContext.setAll(0, defaultMvContext);
    for (int i = 0; i < lfRefDeltas.length; i++) lfRefDeltas[i] = 0;
    for (int i = 0; i < lfModeDeltas.length; i++) lfModeDeltas[i] = 0;
  }

  /// Copy the (already-updated) entropy from a just-parsed frame header
  /// into this persistent state.
  void commitFrom(FrameHeader h) {
    coefProbs.setAll(0, h.coefProbs);
    yModeProb.setAll(0, h.yModeProb);
    uvModeProb.setAll(0, h.uvModeProb);
    mvContext.setAll(0, h.mvContext);
    commitLfFrom(h);
  }

  /// Copy just the LF mode/ref deltas (unconditionally inherited across
  /// frames in libvpx; not gated by refresh_entropy_probs).
  void commitLfFrom(FrameHeader h) {
    lfRefDeltas.setAll(0, h.loopFilter.refDeltas);
    lfModeDeltas.setAll(0, h.loopFilter.modeDeltas);
  }
}

/// Parse a complete VP8 frame header from [frame] and return a populated
/// [FrameHeader]. If [priorState] is provided and the frame is an inter
/// frame, the entropy probability tables are seeded from it before
/// applying the per-frame updates; otherwise they are seeded from the
/// VP8 defaults.
FrameHeader parseFrameHeader(Uint8List frame, {EntropyState? priorState}) {
  if (frame.length < 3) {
    throw const FormatException('VP8 frame shorter than 3-byte tag');
  }

  final h = FrameHeader._();

  // --- Uncompressed 3-byte tag --------------------------------------------
  final int b0 = frame[0];
  final int b1 = frame[1];
  final int b2 = frame[2];
  h.isKeyFrame = (b0 & 1) == 0;
  h.version = (b0 >> 1) & 7;
  h.showFrame = ((b0 >> 4) & 1) != 0;
  h.firstPartitionSize = (b0 | (b1 << 8) | (b2 << 16)) >> 5;
  if (h.firstPartitionSize == 0) {
    throw const FormatException('VP8: zero first-partition length');
  }

  int data = 3;
  if (h.isKeyFrame) {
    if (frame.length < data + 7) {
      throw const FormatException('VP8: truncated key-frame header');
    }
    if (frame[data] != 0x9d ||
        frame[data + 1] != 0x01 ||
        frame[data + 2] != 0x2a) {
      throw const FormatException('VP8: bad keyframe sync code');
    }
    final int wRaw = frame[data + 3] | (frame[data + 4] << 8);
    final int hRaw = frame[data + 5] | (frame[data + 6] << 8);
    h.width = wRaw & 0x3fff;
    h.horizScale = (wRaw >> 14) & 0x3;
    h.height = hRaw & 0x3fff;
    h.vertScale = (hRaw >> 14) & 0x3;
    data += 7;
  }

  // First partition starts here.
  if (data + h.firstPartitionSize > frame.length) {
    throw const FormatException('VP8: first partition runs past end of frame');
  }
  h.residualPartitionsOffset = data + h.firstPartitionSize;

  // The boolean decoder runs over data..data+firstPartitionSize.
  // Note libvpx actually hands the whole remaining buffer to the bool
  // decoder; the partition boundary only matters for the second (token)
  // partition setup. We do the same: pass the rest of the frame so any
  // benign over-read at the very tail of the first partition is harmless.
  final Uint8List firstPart = Uint8List.sublistView(frame, data, frame.length);
  final bc = BoolDecoder(firstPart);

  // --- Color space / clamping (keyframe only) ----------------------------
  if (h.isKeyFrame) {
    h.colorSpace = bc.read(128);
    h.clampingType = bc.read(128);
  }

  // --- Segmentation ------------------------------------------------------
  final seg = h.segmentation;
  seg.enabled = bc.read(128) != 0;
  if (seg.enabled) {
    seg.updateMap = bc.read(128) != 0;
    seg.updateData = bc.read(128) != 0;
    if (seg.updateData) {
      seg.absDelta = bc.read(128) != 0;
      for (int i = 0; i < MbLvl.max; i++) {
        for (int j = 0; j < maxMbSegments; j++) {
          if (bc.read(128) != 0) {
            int v = bc.readLiteral(_mbFeatureDataBits[i]);
            if (bc.read(128) != 0) v = -v;
            seg.featureData[i][j] = v;
          } else {
            seg.featureData[i][j] = 0;
          }
        }
      }
    }
    if (seg.updateMap) {
      for (int i = 0; i < seg.treeProbs.length; i++) {
        seg.treeProbs[i] = 255;
      }
      for (int i = 0; i < mbFeatureTreeProbs; i++) {
        if (bc.read(128) != 0) {
          seg.treeProbs[i] = bc.readLiteral(8);
        }
      }
    }
  }

  // --- Loop filter -------------------------------------------------------
  final lf = h.loopFilter;
  // Inherit persistent deltas from the prior frame (libvpx keeps them in
  // MACROBLOCKD across frames; only an update bit per slot replaces them).
  if (priorState != null && !h.isKeyFrame) {
    lf.refDeltas.setAll(0, priorState.lfRefDeltas);
    lf.modeDeltas.setAll(0, priorState.lfModeDeltas);
  }
  lf.type = bc.read(128);
  lf.level = bc.readLiteral(6);
  lf.sharpness = bc.readLiteral(3);
  lf.modeRefDeltaEnabled = bc.read(128) != 0;
  if (lf.modeRefDeltaEnabled) {
    lf.modeRefDeltaUpdate = bc.read(128) != 0;
    if (lf.modeRefDeltaUpdate) {
      for (int i = 0; i < maxRefLfDeltas; i++) {
        if (bc.read(128) != 0) {
          int v = bc.readLiteral(6);
          if (bc.read(128) != 0) v = -v;
          lf.refDeltas[i] = v;
        }
      }
      for (int i = 0; i < maxModeLfDeltas; i++) {
        if (bc.read(128) != 0) {
          int v = bc.readLiteral(6);
          if (bc.read(128) != 0) v = -v;
          lf.modeDeltas[i] = v;
        }
      }
    }
  }

  // --- Number of residual (token) partitions -----------------------------
  h.log2NumDctPartitions = bc.readLiteral(2);

  // --- Quantizer indices -------------------------------------------------
  final q = h.quantizer;
  q.yAcQi = bc.readLiteral(7);
  q.y1DcDelta = _readDeltaQ(bc);
  q.y2DcDelta = _readDeltaQ(bc);
  q.y2AcDelta = _readDeltaQ(bc);
  q.uvDcDelta = _readDeltaQ(bc);
  q.uvAcDelta = _readDeltaQ(bc);

  // --- Refresh / sign-bias / entropy refresh -----------------------------
  if (!h.isKeyFrame) {
    h.refreshGoldenFrame = bc.read(128) != 0;
    h.refreshAltrefFrame = bc.read(128) != 0;
    if (!h.refreshGoldenFrame) h.copyBufferToGf = bc.readLiteral(2);
    if (!h.refreshAltrefFrame) h.copyBufferToArf = bc.readLiteral(2);
    h.signBiasGolden = bc.read(128) != 0;
    h.signBiasAltref = bc.read(128) != 0;
  } else {
    // Keyframes implicitly refresh all reference buffers from current frame.
    h.refreshGoldenFrame = true;
    h.refreshAltrefFrame = true;
    h.refreshLastFrame = true;
  }

  h.refreshEntropyProbs = bc.read(128) != 0;
  if (!h.isKeyFrame) {
    h.refreshLastFrame = bc.read(128) != 0;
  }

  // --- Token (coefficient) probability updates ---------------------------
  // Inter frames seed from the persistent state (if supplied); keyframes
  // and tests without a state seed from the VP8 defaults.
  if (!h.isKeyFrame && priorState != null) {
    h.coefProbs = Uint8List.fromList(priorState.coefProbs);
  } else {
    h.coefProbs = Uint8List.fromList(defaultCoefProbs);
  }
  for (int i = 0; i < blockTypes; i++) {
    for (int j = 0; j < coefBands; j++) {
      for (int k = 0; k < prevCoefContexts; k++) {
        for (int l = 0; l < entropyNodes; l++) {
          final int idx = coefProbIndex(i, j, k, l);
          if (bc.read(coefUpdateProbs[idx]) != 0) {
            h.coefProbs[idx] = bc.readLiteral(8);
          }
        }
      }
    }
  }

  // --- mb_no_coeff_skip and prob_skip_false ------------------------------
  h.mbNoCoeffSkip = bc.read(128) != 0;
  h.probSkipFalse = h.mbNoCoeffSkip ? bc.readLiteral(8) : 0;

  // --- Inter-frame ref-pred probs and mode/MV prob updates ---------------
  if (!h.isKeyFrame && priorState != null) {
    h.yModeProb = Uint8List.fromList(priorState.yModeProb);
    h.uvModeProb = Uint8List.fromList(priorState.uvModeProb);
    h.mvContext = Uint8List.fromList(priorState.mvContext);
  } else {
    h.yModeProb = Uint8List.fromList(defaultYModeProb);
    h.uvModeProb = Uint8List.fromList(defaultUvModeProb);
    h.mvContext = Uint8List.fromList(defaultMvContext);
  }

  if (!h.isKeyFrame) {
    h.probIntra = bc.readLiteral(8);
    h.probLast = bc.readLiteral(8);
    h.probGf = bc.readLiteral(8);

    if (bc.read(128) != 0) {
      for (int i = 0; i < 4; i++) {
        h.yModeProb[i] = bc.readLiteral(8);
      }
    }
    if (bc.read(128) != 0) {
      for (int i = 0; i < 3; i++) {
        h.uvModeProb[i] = bc.readLiteral(8);
      }
    }

    // MV prob updates. Layout: two contexts of 19 probs each. Update is
    // gated by `mvUpdateProbs[idx]`; the transmitted value is 7 bits and
    // doubled (or set to 1 if zero) per libvpx's `read_mvcontexts`.
    for (int ctx = 0; ctx < 2; ctx++) {
      for (int i = 0; i < mvpCount; i++) {
        final int idx = ctx * mvpCount + i;
        if (bc.read(mvUpdateProbs[idx]) != 0) {
          final int x = bc.readLiteral(7);
          h.mvContext[idx] = x != 0 ? (x << 1) : 1;
        }
      }
    }
  }

  if (bc.error) {
    throw const FormatException('VP8: bool decoder underran first partition');
  }
  h.boolDecoder = bc;
  return h;
}
