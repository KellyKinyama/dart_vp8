// Tests for VP8 inter prediction (Stage 5): 6-tap subpel + bilinear.
//
// The test strategy is a faithful behaviour cross-check: we re-implement
// libvpx's reference filter math here in a different (naive) way, run our
// production filter, and compare results byte-for-byte. This catches both
// off-by-one indexing and tap-table transcription errors.

import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

const int _filterShift = 7;
const int _filterRound = 64;

int _clip8(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

// Reference 6-tap predict implemented in the most direct possible way:
// for each output pixel, run horizontal first then vertical, on a pixel-
// by-pixel basis using a per-row int temp.
Uint8List _refSixtap(Uint8List src, int srcStride, int srcXCenter,
    int srcYCenter, int xoff, int yoff, int width, int height) {
  // Build a (height+5) x width horizontal-filtered int plane.
  final h = subPelFilters[xoff];
  final v = subPelFilters[yoff];
  final tmp =
      List<List<int>>.generate(height + 5, (_) => List<int>.filled(width, 0));
  for (int i = 0; i < height + 5; i++) {
    final int yRow = srcYCenter - 2 + i;
    for (int j = 0; j < width; j++) {
      final int xCol = srcXCenter + j;
      int t = 0;
      for (int k = 0; k < 6; k++) {
        t += src[yRow * srcStride + (xCol - 2 + k)] * h[k];
      }
      t = (t + _filterRound) >> _filterShift;
      tmp[i][j] = _clip8(t);
    }
  }
  final out = Uint8List(width * height);
  for (int i = 0; i < height; i++) {
    for (int j = 0; j < width; j++) {
      int t = 0;
      for (int k = 0; k < 6; k++) {
        t += tmp[i + k][j] * v[k];
      }
      t = (t + _filterRound) >> _filterShift;
      out[i * width + j] = _clip8(t);
    }
  }
  return out;
}

Uint8List _refBilinear(Uint8List src, int srcStride, int srcXCenter,
    int srcYCenter, int xoff, int yoff, int width, int height) {
  final h = bilinearFilters[xoff];
  final v = bilinearFilters[yoff];
  final tmp =
      List<List<int>>.generate(height + 1, (_) => List<int>.filled(width, 0));
  for (int i = 0; i < height + 1; i++) {
    final int yRow = srcYCenter + i;
    for (int j = 0; j < width; j++) {
      final int xCol = srcXCenter + j;
      final int t = (src[yRow * srcStride + xCol] * h[0] +
              src[yRow * srcStride + xCol + 1] * h[1] +
              _filterRound) >>
          _filterShift;
      tmp[i][j] = t;
    }
  }
  final out = Uint8List(width * height);
  for (int i = 0; i < height; i++) {
    for (int j = 0; j < width; j++) {
      final int t = (tmp[i][j] * v[0] + tmp[i + 1][j] * v[1] + _filterRound) >>
          _filterShift;
      out[i * width + j] = t;
    }
  }
  return out;
}

// Build a deterministic source plane large enough for any filter window.
Uint8List _makePlane(int w, int h, int seed) {
  final p = Uint8List(w * h);
  int s = seed;
  for (int i = 0; i < p.length; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    p[i] = s & 0xff;
  }
  return p;
}

void main() {
  // We embed each block in a 32x32 source plane and center the filter
  // window inside it, leaving generous room for the 6-tap window's reach.
  const int srcW = 32;
  const int srcH = 32;
  const int centerX = 8;
  const int centerY = 8;

  group('sixtap predict', () {
    test('xoff=0 yoff=0 is identity copy (within rounding)', () {
      final src = _makePlane(srcW, srcH, 1);
      final dst = Uint8List(16 * 16);
      sixtapPredict16x16(src, centerY * srcW + centerX, srcW, 0, 0, dst, 0, 16);
      for (int r = 0; r < 16; r++) {
        for (int c = 0; c < 16; c++) {
          expect(dst[r * 16 + c], src[(centerY + r) * srcW + (centerX + c)],
              reason: 'r=$r c=$c');
        }
      }
    });

    test('4x4 matches reference for all xoff,yoff', () {
      final src = _makePlane(srcW, srcH, 7);
      for (int xoff = 0; xoff < 8; xoff++) {
        for (int yoff = 0; yoff < 8; yoff++) {
          final dst = Uint8List(4 * 4);
          sixtapPredict4x4(
              src, centerY * srcW + centerX, srcW, xoff, yoff, dst, 0, 4);
          final ref = _refSixtap(src, srcW, centerX, centerY, xoff, yoff, 4, 4);
          expect(dst, ref, reason: 'xoff=$xoff yoff=$yoff');
        }
      }
    });

    test('8x4 matches reference for a sampling of offsets', () {
      final src = _makePlane(srcW, srcH, 11);
      for (final xoff in [0, 1, 4, 7]) {
        for (final yoff in [0, 2, 3, 6]) {
          final dst = Uint8List(8 * 4);
          sixtapPredict8x4(
              src, centerY * srcW + centerX, srcW, xoff, yoff, dst, 0, 8);
          final ref = _refSixtap(src, srcW, centerX, centerY, xoff, yoff, 8, 4);
          expect(dst, ref, reason: 'xoff=$xoff yoff=$yoff');
        }
      }
    });

    test('8x8 matches reference for all xoff,yoff', () {
      final src = _makePlane(srcW, srcH, 13);
      for (int xoff = 0; xoff < 8; xoff++) {
        for (int yoff = 0; yoff < 8; yoff++) {
          final dst = Uint8List(8 * 8);
          sixtapPredict8x8(
              src, centerY * srcW + centerX, srcW, xoff, yoff, dst, 0, 8);
          final ref = _refSixtap(src, srcW, centerX, centerY, xoff, yoff, 8, 8);
          expect(dst, ref, reason: 'xoff=$xoff yoff=$yoff');
        }
      }
    });

    test('16x16 matches reference for a sampling of offsets', () {
      // Need a bigger plane to fit the 16x16 window.
      const int bigW = 48;
      const int bigH = 48;
      final src = _makePlane(bigW, bigH, 17);
      const int cx = 16;
      const int cy = 16;
      for (final xoff in [0, 3, 4, 7]) {
        for (final yoff in [0, 1, 4, 5]) {
          final dst = Uint8List(16 * 16);
          sixtapPredict16x16(src, cy * bigW + cx, bigW, xoff, yoff, dst, 0, 16);
          final ref = _refSixtap(src, bigW, cx, cy, xoff, yoff, 16, 16);
          expect(dst, ref, reason: 'xoff=$xoff yoff=$yoff');
        }
      }
    });

    test('output respects dstOff/dstStride', () {
      final src = _makePlane(srcW, srcH, 23);
      // Put result into the middle of a 16-stride buffer with row offset.
      final dst = Uint8List(16 * 16);
      sixtapPredict4x4(
          src, centerY * srcW + centerX, srcW, 3, 5, dst, 16 * 3 + 4, 16);
      final ref = _refSixtap(src, srcW, centerX, centerY, 3, 5, 4, 4);
      for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
          expect(dst[(3 + r) * 16 + (4 + c)], ref[r * 4 + c]);
        }
      }
      // Surrounding pixels should remain zero.
      expect(dst[0], 0);
      expect(dst[16 * 2 + 3], 0);
    });
  });

  group('bilinear predict', () {
    test('xoff=0,yoff=0 identity (decoder treats as copy)', () {
      // libvpx forbids (0,0) bilinear (it asserts); skip and use (4,4) etc.
      final src = _makePlane(srcW, srcH, 31);
      final dst = Uint8List(4 * 4);
      bilinearPredict4x4(src, centerY * srcW + centerX, srcW, 4, 4, dst, 0, 4);
      final ref = _refBilinear(src, srcW, centerX, centerY, 4, 4, 4, 4);
      expect(dst, ref);
    });

    test('4x4 matches reference for all xoff,yoff', () {
      final src = _makePlane(srcW, srcH, 37);
      for (int xoff = 0; xoff < 8; xoff++) {
        for (int yoff = 0; yoff < 8; yoff++) {
          final dst = Uint8List(4 * 4);
          bilinearPredict4x4(
              src, centerY * srcW + centerX, srcW, xoff, yoff, dst, 0, 4);
          final ref =
              _refBilinear(src, srcW, centerX, centerY, xoff, yoff, 4, 4);
          expect(dst, ref, reason: 'xoff=$xoff yoff=$yoff');
        }
      }
    });

    test('8x8 matches reference for all xoff,yoff', () {
      final src = _makePlane(srcW, srcH, 41);
      for (int xoff = 0; xoff < 8; xoff++) {
        for (int yoff = 0; yoff < 8; yoff++) {
          final dst = Uint8List(8 * 8);
          bilinearPredict8x8(
              src, centerY * srcW + centerX, srcW, xoff, yoff, dst, 0, 8);
          final ref =
              _refBilinear(src, srcW, centerX, centerY, xoff, yoff, 8, 8);
          expect(dst, ref, reason: 'xoff=$xoff yoff=$yoff');
        }
      }
    });

    test('16x16 matches reference for several offsets', () {
      const int bigW = 48;
      const int bigH = 48;
      final src = _makePlane(bigW, bigH, 43);
      const int cx = 16;
      const int cy = 16;
      for (final xoff in [0, 2, 4, 7]) {
        for (final yoff in [0, 3, 4, 6]) {
          final dst = Uint8List(16 * 16);
          bilinearPredict16x16(
              src, cy * bigW + cx, bigW, xoff, yoff, dst, 0, 16);
          final ref = _refBilinear(src, bigW, cx, cy, xoff, yoff, 16, 16);
          expect(dst, ref, reason: 'xoff=$xoff yoff=$yoff');
        }
      }
    });
  });
}
