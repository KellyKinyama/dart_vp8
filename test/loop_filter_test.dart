// Tests for VP8 loop filter (Stage 6).
//
// We verify three things:
//   1. Mask gating: when neighbour deltas exceed the band thresholds the
//      filter must be a no-op. When they are all within limits the filter
//      must modify pixels.
//   2. Filter math: a parallel "naive" reference (independent transcription
//      of libvpx's signed-byte filter formulas, using a simpler style)
//      agrees with the production filter byte-for-byte on a battery of
//      step-edge buffers and random buffers.
//   3. LoopFilterLut: matches libvpx's `vp8_loop_filter_update_sharpness`
//      and `lf_init_lut` tables.

import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

// ---------------- Naive reference (independent transcription) ---------------

int _bias(int b) => b - 128;
int _unbias(int v) => (v ^ 0x80) & 0xff;
int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);
int _abs(int v) => v < 0 ? -v : v;

bool _refMaskOk(int limit, int blimit, int p3, int p2, int p1, int p0, int q0,
    int q1, int q2, int q3) {
  // libvpx: a single failed band-check vetoes filtering.
  final inner = (_abs(p3 - p2) <= limit) &&
      (_abs(p2 - p1) <= limit) &&
      (_abs(p1 - p0) <= limit) &&
      (_abs(q1 - q0) <= limit) &&
      (_abs(q2 - q1) <= limit) &&
      (_abs(q3 - q2) <= limit);
  if (!inner) return false;
  return _abs(p0 - q0) * 2 + (_abs(p1 - q1) >> 1) <= blimit;
}

bool _refHev(int thresh, int p1, int p0, int q0, int q1) =>
    _abs(p1 - p0) > thresh || _abs(q1 - q0) > thresh;

void _refNormal(Uint8List s, int p1i, int p0i, int q0i, int q1i, bool hev) {
  final int p1 = _bias(s[p1i]);
  final int p0 = _bias(s[p0i]);
  final int q0 = _bias(s[q0i]);
  final int q1 = _bias(s[q1i]);

  int fv = hev ? _clamp(p1 - q1, -128, 127) : 0;
  fv = _clamp(fv + 3 * (q0 - p0), -128, 127);
  final int f1 = _clamp(fv + 4, -128, 127) >> 3;
  final int f2 = _clamp(fv + 3, -128, 127) >> 3;
  s[q0i] = _unbias(_clamp(q0 - f1, -128, 127));
  s[p0i] = _unbias(_clamp(p0 + f2, -128, 127));
  if (!hev) {
    final int outer = (f1 + 1) >> 1;
    s[q1i] = _unbias(_clamp(q1 - outer, -128, 127));
    s[p1i] = _unbias(_clamp(p1 + outer, -128, 127));
  }
}

void _refMb(Uint8List s, int p2i, int p1i, int p0i, int q0i, int q1i, int q2i,
    bool hev) {
  final int p2 = _bias(s[p2i]);
  final int p1 = _bias(s[p1i]);
  int p0 = _bias(s[p0i]);
  int q0 = _bias(s[q0i]);
  final int q1 = _bias(s[q1i]);
  final int q2 = _bias(s[q2i]);

  int fv = _clamp(p1 - q1, -128, 127);
  fv = _clamp(fv + 3 * (q0 - p0), -128, 127);
  final int innerFv = hev ? fv : 0;
  final int f1 = _clamp(innerFv + 4, -128, 127) >> 3;
  final int f2 = _clamp(innerFv + 3, -128, 127) >> 3;
  q0 = _clamp(q0 - f1, -128, 127);
  p0 = _clamp(p0 + f2, -128, 127);

  if (hev) {
    s[q0i] = _unbias(q0);
    s[p0i] = _unbias(p0);
    return;
  }
  int u;
  u = _clamp((63 + fv * 27) >> 7, -128, 127);
  s[q0i] = _unbias(_clamp(q0 - u, -128, 127));
  s[p0i] = _unbias(_clamp(p0 + u, -128, 127));

  u = _clamp((63 + fv * 18) >> 7, -128, 127);
  s[q1i] = _unbias(_clamp(q1 - u, -128, 127));
  s[p1i] = _unbias(_clamp(p1 + u, -128, 127));

  u = _clamp((63 + fv * 9) >> 7, -128, 127);
  s[q2i] = _unbias(_clamp(q2 - u, -128, 127));
  s[p2i] = _unbias(_clamp(p2 + u, -128, 127));
}

void _refSimple(Uint8List s, int p1i, int p0i, int q0i, int q1i) {
  final int p1 = _bias(s[p1i]);
  final int p0 = _bias(s[p0i]);
  final int q0 = _bias(s[q0i]);
  final int q1 = _bias(s[q1i]);
  int fv = _clamp(p1 - q1, -128, 127);
  fv = _clamp(fv + 3 * (q0 - p0), -128, 127);
  final int f1 = _clamp(fv + 4, -128, 127) >> 3;
  s[q0i] = _unbias(_clamp(q0 - f1, -128, 127));
  final int f2 = _clamp(fv + 3, -128, 127) >> 3;
  s[p0i] = _unbias(_clamp(p0 + f2, -128, 127));
}

void _refHorizEdge(Uint8List s, int off, int pitch, int blimit, int limit,
    int thresh, int count) {
  for (int i = 0; i < count * 8; i++) {
    final int idx = off + i;
    if (!_refMaskOk(
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
    final bool hev = _refHev(thresh, s[idx - 2 * pitch], s[idx - 1 * pitch],
        s[idx], s[idx + 1 * pitch]);
    _refNormal(s, idx - 2 * pitch, idx - 1 * pitch, idx, idx + 1 * pitch, hev);
  }
}

void _refVertEdge(Uint8List s, int off, int pitch, int blimit, int limit,
    int thresh, int count) {
  for (int i = 0; i < count * 8; i++) {
    final int idx = off + i * pitch;
    if (!_refMaskOk(limit, blimit, s[idx - 4], s[idx - 3], s[idx - 2],
        s[idx - 1], s[idx + 0], s[idx + 1], s[idx + 2], s[idx + 3])) {
      continue;
    }
    final bool hev =
        _refHev(thresh, s[idx - 2], s[idx - 1], s[idx], s[idx + 1]);
    _refNormal(s, idx - 2, idx - 1, idx, idx + 1, hev);
  }
}

void _refMbHorizEdge(Uint8List s, int off, int pitch, int blimit, int limit,
    int thresh, int count) {
  for (int i = 0; i < count * 8; i++) {
    final int idx = off + i;
    if (!_refMaskOk(
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
    final bool hev = _refHev(thresh, s[idx - 2 * pitch], s[idx - 1 * pitch],
        s[idx], s[idx + 1 * pitch]);
    _refMb(s, idx - 3 * pitch, idx - 2 * pitch, idx - 1 * pitch, idx,
        idx + 1 * pitch, idx + 2 * pitch, hev);
  }
}

void _refMbVertEdge(Uint8List s, int off, int pitch, int blimit, int limit,
    int thresh, int count) {
  for (int i = 0; i < count * 8; i++) {
    final int idx = off + i * pitch;
    if (!_refMaskOk(limit, blimit, s[idx - 4], s[idx - 3], s[idx - 2],
        s[idx - 1], s[idx + 0], s[idx + 1], s[idx + 2], s[idx + 3])) {
      continue;
    }
    final bool hev =
        _refHev(thresh, s[idx - 2], s[idx - 1], s[idx], s[idx + 1]);
    _refMb(s, idx - 3, idx - 2, idx - 1, idx, idx + 1, idx + 2, hev);
  }
}

void _refSimpleH(Uint8List y, int off, int stride, int blimit) {
  for (int i = 0; i < 16; i++) {
    final int idx = off + i;
    if (_abs(y[idx - 1 * stride] - y[idx]) * 2 +
            (_abs(y[idx - 2 * stride] - y[idx + 1 * stride]) >> 1) >
        blimit) {
      continue;
    }
    _refSimple(y, idx - 2 * stride, idx - 1 * stride, idx, idx + 1 * stride);
  }
}

void _refSimpleV(Uint8List y, int off, int stride, int blimit) {
  for (int i = 0; i < 16; i++) {
    final int idx = off + i * stride;
    if (_abs(y[idx - 1] - y[idx]) * 2 + (_abs(y[idx - 2] - y[idx + 1]) >> 1) >
        blimit) {
      continue;
    }
    _refSimple(y, idx - 2, idx - 1, idx, idx + 1);
  }
}

// ---------------- Helpers ---------------------------------------------------

Uint8List _seeded(int n, int seed) {
  final out = Uint8List(n);
  int s = seed;
  for (int i = 0; i < n; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    out[i] = s & 0xff;
  }
  return out;
}

Uint8List _stepRow(int w, int h, int rowSplit, int hi, int lo) {
  final out = Uint8List(w * h);
  for (int r = 0; r < h; r++) {
    final v = r < rowSplit ? hi : lo;
    for (int c = 0; c < w; c++) {
      out[r * w + c] = v;
    }
  }
  return out;
}

Uint8List _stepCol(int w, int h, int colSplit, int hi, int lo) {
  final out = Uint8List(w * h);
  for (int r = 0; r < h; r++) {
    for (int c = 0; c < w; c++) {
      out[r * w + c] = c < colSplit ? hi : lo;
    }
  }
  return out;
}

void _expectBytesEqual(Uint8List a, Uint8List b, String reason) {
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      fail('byte $i differs: ${a[i]} vs ${b[i]} ($reason)');
    }
  }
}

// ---------------- Tests -----------------------------------------------------

void main() {
  const int blimit = 20;
  const int limit = 10;
  const int thresh = 7;

  group('mask gating', () {
    test('large jump (well above blimit) is a no-op', () {
      final w = 32, h = 32;
      final a = _stepRow(w, h, 16, 50, 200);
      final orig = Uint8List.fromList(a);
      loopFilterHorizontalEdge(a, 16 * w + 8, w, blimit, limit, thresh, 2);
      _expectBytesEqual(a, orig, 'big jump → no-op');
    });
    test('small smooth gradient triggers filter', () {
      final w = 32, h = 32;
      final a = _stepRow(w, h, 16, 120, 122);
      final orig = Uint8List.fromList(a);
      loopFilterHorizontalEdge(a, 16 * w + 8, w, blimit, limit, thresh, 2);
      // At least one pixel near the edge should have changed.
      bool changed = false;
      for (int i = 0; i < a.length; i++) {
        if (a[i] != orig[i]) {
          changed = true;
          break;
        }
      }
      expect(changed, isTrue, reason: 'expected filter to fire on small jump');
    });
  });

  group('production matches naive reference', () {
    test('horizontal: small step', () {
      final w = 32, h = 32;
      final a = _stepRow(w, h, 16, 120, 122);
      final b = Uint8List.fromList(a);
      loopFilterHorizontalEdge(a, 16 * w + 8, w, blimit, limit, thresh, 2);
      _refHorizEdge(b, 16 * w + 8, w, blimit, limit, thresh, 2);
      _expectBytesEqual(a, b, 'horiz-step');
    });
    test('horizontal: random', () {
      final w = 32, h = 32;
      final a = _seeded(w * h, 1);
      final b = Uint8List.fromList(a);
      loopFilterHorizontalEdge(a, 8 * w + 8, w, 100, 50, 7, 2);
      _refHorizEdge(b, 8 * w + 8, w, 100, 50, 7, 2);
      _expectBytesEqual(a, b, 'horiz-rand');
    });
    test('vertical: small step', () {
      final w = 32, h = 32;
      final a = _stepCol(w, h, 16, 120, 122);
      final b = Uint8List.fromList(a);
      loopFilterVerticalEdge(a, 8 * w + 16, w, blimit, limit, thresh, 2);
      _refVertEdge(b, 8 * w + 16, w, blimit, limit, thresh, 2);
      _expectBytesEqual(a, b, 'vert-step');
    });
    test('vertical: random with relaxed thresholds', () {
      final w = 32, h = 32;
      final a = _seeded(w * h, 2);
      final b = Uint8List.fromList(a);
      loopFilterVerticalEdge(a, 8 * w + 16, w, 100, 50, 7, 2);
      _refVertEdge(b, 8 * w + 16, w, 100, 50, 7, 2);
      _expectBytesEqual(a, b, 'vert-rand');
    });
    test('mb horizontal: small step', () {
      final w = 32, h = 32;
      final a = _stepRow(w, h, 16, 120, 124);
      final b = Uint8List.fromList(a);
      mbLoopFilterHorizontalEdge(a, 16 * w + 8, w, blimit, limit, thresh, 2);
      _refMbHorizEdge(b, 16 * w + 8, w, blimit, limit, thresh, 2);
      _expectBytesEqual(a, b, 'mbh-step');
    });
    test('mb vertical: small step', () {
      final w = 32, h = 32;
      final a = _stepCol(w, h, 16, 120, 124);
      final b = Uint8List.fromList(a);
      mbLoopFilterVerticalEdge(a, 8 * w + 16, w, blimit, limit, thresh, 2);
      _refMbVertEdge(b, 8 * w + 16, w, blimit, limit, thresh, 2);
      _expectBytesEqual(a, b, 'mbv-step');
    });
    test('mb horizontal: random (relaxed thresholds)', () {
      final w = 32, h = 32;
      final a = _seeded(w * h, 3);
      final b = Uint8List.fromList(a);
      mbLoopFilterHorizontalEdge(a, 16 * w + 8, w, 200, 100, 7, 2);
      _refMbHorizEdge(b, 16 * w + 8, w, 200, 100, 7, 2);
      _expectBytesEqual(a, b, 'mbh-rand');
    });
    test('mb horizontal: hev=true on every other column', () {
      final w = 32, h = 32;
      // Build pattern that yields some hev=true (high p1-p0/q1-q0 jump) and
      // some hev=false columns, both within the band limit overall.
      final a = Uint8List(w * h);
      for (int r = 0; r < h; r++) {
        for (int c = 0; c < w; c++) {
          int base = r < 16 ? 120 : 124;
          // alternating-row jitter in the strip near the edge to push hev
          if (r >= 12 && r <= 19 && (c & 1) == 0) {
            base += (r & 1) == 0 ? -3 : 3;
          }
          a[r * w + c] = base;
        }
      }
      final b = Uint8List.fromList(a);
      mbLoopFilterHorizontalEdge(a, 16 * w + 8, w, 40, 10, 4, 2);
      _refMbHorizEdge(b, 16 * w + 8, w, 40, 10, 4, 2);
      _expectBytesEqual(a, b, 'mbh-hev-mix');
    });
    test('simple horizontal: small step', () {
      final w = 32, h = 32;
      final a = _stepRow(w, h, 16, 120, 124);
      final b = Uint8List.fromList(a);
      loopFilterSimpleHorizontalEdge(a, 16 * w + 8, w, blimit);
      _refSimpleH(b, 16 * w + 8, w, blimit);
      _expectBytesEqual(a, b, 'simpleH-step');
    });
    test('simple vertical: small step', () {
      final w = 32, h = 32;
      final a = _stepCol(w, h, 16, 120, 124);
      final b = Uint8List.fromList(a);
      loopFilterSimpleVerticalEdge(a, 8 * w + 16, w, blimit);
      _refSimpleV(b, 8 * w + 16, w, blimit);
      _expectBytesEqual(a, b, 'simpleV-step');
    });
    test('simple horizontal: random (relaxed blimit)', () {
      final w = 32, h = 32;
      final a = _seeded(w * h, 4);
      final b = Uint8List.fromList(a);
      loopFilterSimpleHorizontalEdge(a, 16 * w + 8, w, 200);
      _refSimpleH(b, 16 * w + 8, w, 200);
      _expectBytesEqual(a, b, 'simpleH-rand');
    });
  });

  group('LoopFilterLut', () {
    test('sharpness 0 gives lim = max(1, filterLvl)', () {
      final lut = LoopFilterLut.forSharpness(0);
      for (int lv = 0; lv <= maxLoopFilter; lv++) {
        final int e = lv < 1 ? 1 : lv;
        expect(lut.lim[lv], e, reason: 'lv=$lv');
        expect(lut.blim[lv], 2 * lv + e);
        expect(lut.mblim[lv], 2 * (lv + 2) + e);
      }
    });
    test('sharpness 1: lim = max(1, min(8, filterLvl>>1))', () {
      final lut = LoopFilterLut.forSharpness(1);
      for (int lv = 0; lv <= maxLoopFilter; lv++) {
        int e = lv >> 1;
        if (e > 8) e = 8;
        if (e < 1) e = 1;
        expect(lut.lim[lv], e, reason: 'lv=$lv');
      }
    });
    test('sharpness 7: lim capped at 2', () {
      final lut = LoopFilterLut.forSharpness(7);
      for (int lv = 0; lv <= maxLoopFilter; lv++) {
        int e = (lv >> 1) >> 1;
        if (e > 2) e = 2;
        if (e < 1) e = 1;
        expect(lut.lim[lv], e, reason: 'lv=$lv');
      }
    });
    test('hev threshold step table', () {
      final lut = LoopFilterLut.forSharpness(0);
      expect(lut.hevThrIndex(frameKey, 0), 0);
      expect(lut.hevThrIndex(frameKey, 14), 0);
      expect(lut.hevThrIndex(frameKey, 15), 1);
      expect(lut.hevThrIndex(frameKey, 19), 1);
      expect(lut.hevThrIndex(frameKey, 20), 1);
      expect(lut.hevThrIndex(frameKey, 39), 1);
      expect(lut.hevThrIndex(frameKey, 40), 2);
      expect(lut.hevThrIndex(frameInter, 14), 0);
      expect(lut.hevThrIndex(frameInter, 15), 1);
      expect(lut.hevThrIndex(frameInter, 20), 2);
      expect(lut.hevThrIndex(frameInter, 40), 3);
    });
  });

  test('per-MB driver dispatches to primitives', () {
    final w = 64;
    final y = _seeded(w * w, 5);
    final u = _seeded(w * w, 6);
    final v = _seeded(w * w, 7);
    final y2 = Uint8List.fromList(y);
    final u2 = Uint8List.fromList(u);
    final v2 = Uint8List.fromList(v);
    const lfi = LoopFilterInfo(80, 60, 30, 7);
    loopFilterMbh(y, 16 * w + 16, w, u, 16 * w + 16, v, 16 * w + 16, w, lfi);
    mbLoopFilterHorizontalEdge(y2, 16 * w + 16, w, 80, 30, 7, 2);
    mbLoopFilterHorizontalEdge(u2, 16 * w + 16, w, 80, 30, 7, 1);
    mbLoopFilterHorizontalEdge(v2, 16 * w + 16, w, 80, 30, 7, 1);
    _expectBytesEqual(y, y2, 'mbh y');
    _expectBytesEqual(u, u2, 'mbh u');
    _expectBytesEqual(v, v2, 'mbh v');
  });
}
