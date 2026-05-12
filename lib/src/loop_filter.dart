// VP8 loop filter.
//
// Verbatim port of vp8/common/loopfilter_filters.c (filter math) plus the
// sharpness/level → thresholds helpers from vp8/common/vp8_loopfilter.c.
//
// libvpx's filter math is written in terms of `signed char` values: bytes
// are biased by XOR 0x80 to land in [-128, 127], operations are done in
// that signed-byte range with explicit clamping (`vp8_signed_char_clamp`),
// and the result is biased back. We do the same here; the bias helpers
// use `^ 0x80` for the round-trip and `_sccl` clamps to [-128, 127].
//
// libvpx's `mask` / `hev` are byte-wide signed masks (0 or -1) that gate
// updates via `&`. We represent them as Dart `bool`s and gate the writes
// directly; the result is byte-identical.
//
// The actual per-frame driver (iterate MBs, look at segment_id/ref_frame/
// mode/skip_coeff to pick filter_level, then dispatch mbh/mbv/bh/bv) lives
// in Stage 7 where MODE_INFO is available. Here we expose the per-edge
// primitives, the per-MB convenience entry points, and the level→
// thresholds table.

import 'dart:typed_data';

const int frameKey = 0;
const int frameInter = 1;

/// Maximum allowed loop filter level (RFC 6386).
const int maxLoopFilter = 63;

// Convert unsigned byte to libvpx's "signed char" bias-flipped form.
// (byte ^ 0x80) reinterprets the byte as a signed value in [-128, 127].
int _bias(int b) => b - 128;

// Inverse of _bias: take a signed value (clamped to [-128, 127]) and pack
// back to an unsigned byte.
int _unbias(int v) => (v ^ 0x80) & 0xff;

// Signed-char clamp [-128, 127].
int _sccl(int t) => t < -128 ? -128 : (t > 127 ? 127 : t);

int _abs(int v) => v < 0 ? -v : v;

bool _filterMask(int limit, int blimit, int p3, int p2, int p1, int p0, int q0,
    int q1, int q2, int q3) {
  if (_abs(p3 - p2) > limit) return false;
  if (_abs(p2 - p1) > limit) return false;
  if (_abs(p1 - p0) > limit) return false;
  if (_abs(q1 - q0) > limit) return false;
  if (_abs(q2 - q1) > limit) return false;
  if (_abs(q3 - q2) > limit) return false;
  if (_abs(p0 - q0) * 2 + (_abs(p1 - q1) >> 1) > blimit) return false;
  return true;
}

bool _hevMask(int thresh, int p1, int p0, int q0, int q1) =>
    _abs(p1 - p0) > thresh || _abs(q1 - q0) > thresh;

// Normal 4-tap filter across an edge. Caller has verified mask==true.
void _vp8Filter(
    bool hev, Uint8List s, int op1Idx, int op0Idx, int oq0Idx, int oq1Idx) {
  final int ps1 = _bias(s[op1Idx]);
  final int ps0 = _bias(s[op0Idx]);
  final int qs0 = _bias(s[oq0Idx]);
  final int qs1 = _bias(s[oq1Idx]);

  // Outer-tap contribution only when hev.
  int fv = hev ? _sccl(ps1 - qs1) : 0;
  fv = _sccl(fv + 3 * (qs0 - ps0));
  // mask is true (caller-gated).

  // After _sccl, values are in [-128, 127] where Dart's `>>` already does
  // arithmetic shift correctly.
  final int f1 = _sccl(fv + 4) >> 3;
  final int f2 = _sccl(fv + 3) >> 3;

  s[oq0Idx] = _unbias(_sccl(qs0 - f1));
  s[op0Idx] = _unbias(_sccl(ps0 + f2));

  if (!hev) {
    final int outer = (f1 + 1) >> 1;
    s[oq1Idx] = _unbias(_sccl(qs1 - outer));
    s[op1Idx] = _unbias(_sccl(ps1 + outer));
  }
}

// 6-tap MB filter across an MB edge. Caller has verified mask==true.
void _vp8MbFilter(bool hev, Uint8List s, int op2Idx, int op1Idx, int op0Idx,
    int oq0Idx, int oq1Idx, int oq2Idx) {
  final int ps2 = _bias(s[op2Idx]);
  final int ps1 = _bias(s[op1Idx]);
  int ps0 = _bias(s[op0Idx]);
  int qs0 = _bias(s[oq0Idx]);
  final int qs1 = _bias(s[oq1Idx]);
  final int qs2 = _bias(s[oq2Idx]);

  int fv = _sccl(ps1 - qs1);
  fv = _sccl(fv + 3 * (qs0 - ps0));
  // mask is true (caller-gated).

  // Inner-tap (hev) update: filter2 = filterValue when hev else 0.
  final int filter2InnerTap = hev ? fv : 0;
  final int f1 = _sccl(filter2InnerTap + 4) >> 3;
  final int f2 = _sccl(filter2InnerTap + 3) >> 3;
  qs0 = _sccl(qs0 - f1);
  ps0 = _sccl(ps0 + f2);

  if (hev) {
    // Wider filter contributes 0 in this branch.
    s[oq0Idx] = _unbias(qs0);
    s[op0Idx] = _unbias(ps0);
    return;
  }

  // Wider 6-tap filter, applied only when !hev.
  int u;
  u = _sccl((63 + fv * 27) >> 7);
  s[oq0Idx] = _unbias(_sccl(qs0 - u));
  s[op0Idx] = _unbias(_sccl(ps0 + u));

  u = _sccl((63 + fv * 18) >> 7);
  s[oq1Idx] = _unbias(_sccl(qs1 - u));
  s[op1Idx] = _unbias(_sccl(ps1 + u));

  u = _sccl((63 + fv * 9) >> 7);
  s[oq2Idx] = _unbias(_sccl(qs2 - u));
  s[op2Idx] = _unbias(_sccl(ps2 + u));
}

void loopFilterHorizontalEdge(Uint8List s, int sOff, int pitch, int blimit,
    int limit, int thresh, int count) {
  for (int i = 0; i < count * 8; i++) {
    final int idx = sOff + i;
    if (!_filterMask(
        limit,
        blimit,
        s[idx - 4 * pitch],
        s[idx - 3 * pitch],
        s[idx - 2 * pitch],
        s[idx - 1 * pitch],
        s[idx + 0 * pitch],
        s[idx + 1 * pitch],
        s[idx + 2 * pitch],
        s[idx + 3 * pitch])) {
      continue;
    }
    final bool hev = _hevMask(thresh, s[idx - 2 * pitch], s[idx - 1 * pitch],
        s[idx], s[idx + 1 * pitch]);
    _vp8Filter(hev, s, idx - 2 * pitch, idx - 1 * pitch, idx, idx + 1 * pitch);
  }
}

void loopFilterVerticalEdge(Uint8List s, int sOff, int pitch, int blimit,
    int limit, int thresh, int count) {
  for (int i = 0; i < count * 8; i++) {
    final int idx = sOff + i * pitch;
    if (!_filterMask(limit, blimit, s[idx - 4], s[idx - 3], s[idx - 2],
        s[idx - 1], s[idx + 0], s[idx + 1], s[idx + 2], s[idx + 3])) {
      continue;
    }
    final bool hev =
        _hevMask(thresh, s[idx - 2], s[idx - 1], s[idx], s[idx + 1]);
    _vp8Filter(hev, s, idx - 2, idx - 1, idx, idx + 1);
  }
}

void mbLoopFilterHorizontalEdge(Uint8List s, int sOff, int pitch, int blimit,
    int limit, int thresh, int count) {
  for (int i = 0; i < count * 8; i++) {
    final int idx = sOff + i;
    if (!_filterMask(
        limit,
        blimit,
        s[idx - 4 * pitch],
        s[idx - 3 * pitch],
        s[idx - 2 * pitch],
        s[idx - 1 * pitch],
        s[idx + 0 * pitch],
        s[idx + 1 * pitch],
        s[idx + 2 * pitch],
        s[idx + 3 * pitch])) {
      continue;
    }
    final bool hev = _hevMask(thresh, s[idx - 2 * pitch], s[idx - 1 * pitch],
        s[idx], s[idx + 1 * pitch]);
    _vp8MbFilter(hev, s, idx - 3 * pitch, idx - 2 * pitch, idx - 1 * pitch, idx,
        idx + 1 * pitch, idx + 2 * pitch);
  }
}

void mbLoopFilterVerticalEdge(Uint8List s, int sOff, int pitch, int blimit,
    int limit, int thresh, int count) {
  for (int i = 0; i < count * 8; i++) {
    final int idx = sOff + i * pitch;
    if (!_filterMask(limit, blimit, s[idx - 4], s[idx - 3], s[idx - 2],
        s[idx - 1], s[idx + 0], s[idx + 1], s[idx + 2], s[idx + 3])) {
      continue;
    }
    final bool hev =
        _hevMask(thresh, s[idx - 2], s[idx - 1], s[idx], s[idx + 1]);
    _vp8MbFilter(hev, s, idx - 3, idx - 2, idx - 1, idx, idx + 1, idx + 2);
  }
}

// ---------------------------------------------------------------------------
// Simple filter (Y plane only).

bool _simpleFilterMask(int blimit, int p1, int p0, int q0, int q1) =>
    _abs(p0 - q0) * 2 + (_abs(p1 - q1) >> 1) <= blimit;

void _vp8SimpleFilter(
    Uint8List s, int op1Idx, int op0Idx, int oq0Idx, int oq1Idx) {
  final int p1 = _bias(s[op1Idx]);
  final int p0 = _bias(s[op0Idx]);
  final int q0 = _bias(s[oq0Idx]);
  final int q1 = _bias(s[oq1Idx]);

  int fv = _sccl(p1 - q1);
  fv = _sccl(fv + 3 * (q0 - p0));

  final int f1 = _sccl(fv + 4) >> 3;
  s[oq0Idx] = _unbias(_sccl(q0 - f1));

  final int f2 = _sccl(fv + 3) >> 3;
  s[op0Idx] = _unbias(_sccl(p0 + f2));
}

void loopFilterSimpleHorizontalEdge(
    Uint8List y, int yOff, int yStride, int blimit) {
  for (int i = 0; i < 16; i++) {
    final int idx = yOff + i;
    if (!_simpleFilterMask(blimit, y[idx - 2 * yStride], y[idx - 1 * yStride],
        y[idx], y[idx + 1 * yStride])) {
      continue;
    }
    _vp8SimpleFilter(
        y, idx - 2 * yStride, idx - 1 * yStride, idx, idx + 1 * yStride);
  }
}

void loopFilterSimpleVerticalEdge(
    Uint8List y, int yOff, int yStride, int blimit) {
  for (int i = 0; i < 16; i++) {
    final int idx = yOff + i * yStride;
    if (!_simpleFilterMask(
        blimit, y[idx - 2], y[idx - 1], y[idx], y[idx + 1])) {
      continue;
    }
    _vp8SimpleFilter(y, idx - 2, idx - 1, idx, idx + 1);
  }
}

// ---------------------------------------------------------------------------
// Per-MB convenience entry points.

class LoopFilterInfo {
  final int mblim;
  final int blim;
  final int lim;
  final int hevThr;
  const LoopFilterInfo(this.mblim, this.blim, this.lim, this.hevThr);
}

void loopFilterMbh(
  Uint8List y,
  int yOff,
  int yStride,
  Uint8List? u,
  int uOff,
  Uint8List? v,
  int vOff,
  int uvStride,
  LoopFilterInfo lfi,
) {
  mbLoopFilterHorizontalEdge(
      y, yOff, yStride, lfi.mblim, lfi.lim, lfi.hevThr, 2);
  if (u != null) {
    mbLoopFilterHorizontalEdge(
        u, uOff, uvStride, lfi.mblim, lfi.lim, lfi.hevThr, 1);
  }
  if (v != null) {
    mbLoopFilterHorizontalEdge(
        v, vOff, uvStride, lfi.mblim, lfi.lim, lfi.hevThr, 1);
  }
}

void loopFilterMbv(
  Uint8List y,
  int yOff,
  int yStride,
  Uint8List? u,
  int uOff,
  Uint8List? v,
  int vOff,
  int uvStride,
  LoopFilterInfo lfi,
) {
  mbLoopFilterVerticalEdge(y, yOff, yStride, lfi.mblim, lfi.lim, lfi.hevThr, 2);
  if (u != null) {
    mbLoopFilterVerticalEdge(
        u, uOff, uvStride, lfi.mblim, lfi.lim, lfi.hevThr, 1);
  }
  if (v != null) {
    mbLoopFilterVerticalEdge(
        v, vOff, uvStride, lfi.mblim, lfi.lim, lfi.hevThr, 1);
  }
}

void loopFilterBh(
  Uint8List y,
  int yOff,
  int yStride,
  Uint8List? u,
  int uOff,
  Uint8List? v,
  int vOff,
  int uvStride,
  LoopFilterInfo lfi,
) {
  loopFilterHorizontalEdge(
      y, yOff + 4 * yStride, yStride, lfi.blim, lfi.lim, lfi.hevThr, 2);
  loopFilterHorizontalEdge(
      y, yOff + 8 * yStride, yStride, lfi.blim, lfi.lim, lfi.hevThr, 2);
  loopFilterHorizontalEdge(
      y, yOff + 12 * yStride, yStride, lfi.blim, lfi.lim, lfi.hevThr, 2);
  if (u != null) {
    loopFilterHorizontalEdge(
        u, uOff + 4 * uvStride, uvStride, lfi.blim, lfi.lim, lfi.hevThr, 1);
  }
  if (v != null) {
    loopFilterHorizontalEdge(
        v, vOff + 4 * uvStride, uvStride, lfi.blim, lfi.lim, lfi.hevThr, 1);
  }
}

void loopFilterBv(
  Uint8List y,
  int yOff,
  int yStride,
  Uint8List? u,
  int uOff,
  Uint8List? v,
  int vOff,
  int uvStride,
  LoopFilterInfo lfi,
) {
  loopFilterVerticalEdge(
      y, yOff + 4, yStride, lfi.blim, lfi.lim, lfi.hevThr, 2);
  loopFilterVerticalEdge(
      y, yOff + 8, yStride, lfi.blim, lfi.lim, lfi.hevThr, 2);
  loopFilterVerticalEdge(
      y, yOff + 12, yStride, lfi.blim, lfi.lim, lfi.hevThr, 2);
  if (u != null) {
    loopFilterVerticalEdge(
        u, uOff + 4, uvStride, lfi.blim, lfi.lim, lfi.hevThr, 1);
  }
  if (v != null) {
    loopFilterVerticalEdge(
        v, vOff + 4, uvStride, lfi.blim, lfi.lim, lfi.hevThr, 1);
  }
}

void loopFilterBhs(Uint8List y, int yOff, int yStride, int blimit) {
  loopFilterSimpleHorizontalEdge(y, yOff + 4 * yStride, yStride, blimit);
  loopFilterSimpleHorizontalEdge(y, yOff + 8 * yStride, yStride, blimit);
  loopFilterSimpleHorizontalEdge(y, yOff + 12 * yStride, yStride, blimit);
}

void loopFilterBvs(Uint8List y, int yOff, int yStride, int blimit) {
  loopFilterSimpleVerticalEdge(y, yOff + 4, yStride, blimit);
  loopFilterSimpleVerticalEdge(y, yOff + 8, yStride, blimit);
  loopFilterSimpleVerticalEdge(y, yOff + 12, yStride, blimit);
}

// ---------------------------------------------------------------------------
// Level / sharpness → threshold table (per-frame setup).

/// Precomputed thresholds for each of the 64 possible filter levels (0..63),
/// plus the per-frame-type hev-threshold-index LUT. Matches
/// `vp8_loop_filter_update_sharpness` + `lf_init_lut`.
class LoopFilterLut {
  final Uint8List mblim;
  final Uint8List blim;
  final Uint8List lim;
  final Uint8List hevThrLut;

  LoopFilterLut._(this.mblim, this.blim, this.lim, this.hevThrLut);

  factory LoopFilterLut.forSharpness(int sharpnessLvl) {
    final mblim = Uint8List(maxLoopFilter + 1);
    final blim = Uint8List(maxLoopFilter + 1);
    final lim = Uint8List(maxLoopFilter + 1);
    for (int filtLvl = 0; filtLvl <= maxLoopFilter; filtLvl++) {
      int blockInsideLimit = filtLvl >> (sharpnessLvl > 0 ? 1 : 0);
      blockInsideLimit = blockInsideLimit >> (sharpnessLvl > 4 ? 1 : 0);
      if (sharpnessLvl > 0) {
        if (blockInsideLimit > (9 - sharpnessLvl)) {
          blockInsideLimit = 9 - sharpnessLvl;
        }
      }
      if (blockInsideLimit < 1) blockInsideLimit = 1;
      lim[filtLvl] = blockInsideLimit;
      blim[filtLvl] = 2 * filtLvl + blockInsideLimit;
      mblim[filtLvl] = 2 * (filtLvl + 2) + blockInsideLimit;
    }
    final hev = Uint8List(2 * (maxLoopFilter + 1));
    for (int filtLvl = 0; filtLvl <= maxLoopFilter; filtLvl++) {
      int k, i;
      if (filtLvl >= 40) {
        k = 2;
        i = 3;
      } else if (filtLvl >= 20) {
        k = 1;
        i = 2;
      } else if (filtLvl >= 15) {
        k = 1;
        i = 1;
      } else {
        k = 0;
        i = 0;
      }
      hev[frameKey * (maxLoopFilter + 1) + filtLvl] = k;
      hev[frameInter * (maxLoopFilter + 1) + filtLvl] = i;
    }
    return LoopFilterLut._(mblim, blim, lim, hev);
  }

  int hevThrIndex(int frameType, int filterLevel) =>
      hevThrLut[frameType * (maxLoopFilter + 1) + filterLevel];

  LoopFilterInfo infoFor(int frameType, int filterLevel) => LoopFilterInfo(
      mblim[filterLevel],
      blim[filterLevel],
      lim[filterLevel],
      hevThrIndex(frameType, filterLevel));
}
