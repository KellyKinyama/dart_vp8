// Tests for VP8 intra prediction (Stage 4).

import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

Uint8List _zeros(int n) => Uint8List(n);
Uint8List _fill(int n, int v) {
  final b = Uint8List(n);
  for (int i = 0; i < n; i++) {
    b[i] = v;
  }
  return b;
}

int _avg3(int a, int b, int c) => (a + 2 * b + c + 2) >> 2;

void main() {
  group('16x16 luma', () {
    test('V_PRED replicates above row', () {
      final dst = _zeros(16 * 16);
      final above = Uint8List.fromList(List.generate(16, (i) => i * 8));
      final left = _zeros(16);
      predict16x16(vPred, dst, 0, 16, above, 0, left, 0, 0, true, true);
      for (int r = 0; r < 16; r++) {
        for (int c = 0; c < 16; c++) {
          expect(dst[r * 16 + c], above[c]);
        }
      }
    });

    test('H_PRED replicates left column', () {
      final dst = _zeros(16 * 16);
      final above = _zeros(16);
      final left = Uint8List.fromList(List.generate(16, (i) => i * 8));
      predict16x16(hPred, dst, 0, 16, above, 0, left, 0, 0, true, true);
      for (int r = 0; r < 16; r++) {
        for (int c = 0; c < 16; c++) {
          expect(dst[r * 16 + c], left[r]);
        }
      }
    });

    test('DC_PRED both available rounds to (sum+16)/32', () {
      final above = _fill(16, 100);
      final left = _fill(16, 60);
      final dst = _zeros(16 * 16);
      predict16x16(dcPred, dst, 0, 16, above, 0, left, 0, 0, true, true);
      // (100*16 + 60*16 + 16)/32 = (1600 + 960 + 16)/32 = 2576/32 = 80
      for (int i = 0; i < 256; i++) {
        expect(dst[i], 80);
      }
    });

    test('DC_PRED only top uses (sum+8)/16', () {
      final above = _fill(16, 50);
      final left = _zeros(16);
      final dst = _zeros(16 * 16);
      predict16x16(dcPred, dst, 0, 16, above, 0, left, 0, 0, true, false);
      for (int i = 0; i < 256; i++) {
        expect(dst[i], 50);
      }
    });

    test('DC_PRED neither available fills 128', () {
      final dst = _zeros(16 * 16);
      predict16x16(
          dcPred, dst, 0, 16, _zeros(16), 0, _zeros(16), 0, 0, false, false);
      for (int i = 0; i < 256; i++) {
        expect(dst[i], 128);
      }
    });

    test('TM_PRED clamps and is left + above - top_left', () {
      final above = Uint8List.fromList(List.generate(16, (i) => 100 + i));
      final left = Uint8List.fromList(List.generate(16, (i) => 50 + i));
      final dst = _zeros(16 * 16);
      predict16x16(tmPred, dst, 0, 16, above, 0, left, 0, 80, true, true);
      for (int r = 0; r < 16; r++) {
        for (int c = 0; c < 16; c++) {
          final exp0 = left[r] + above[c] - 80;
          final exp = exp0 < 0 ? 0 : (exp0 > 255 ? 255 : exp0);
          expect(dst[r * 16 + c], exp, reason: 'r=$r c=$c');
        }
      }
    });
  });

  group('4x4 B-modes', () {
    test('B_DC averages above[0..3] + left[0..3] + 4', () {
      final above = Uint8List.fromList([10, 20, 30, 40, 0, 0, 0, 0]);
      final left = Uint8List.fromList([50, 60, 70, 80]);
      final dst = _zeros(16);
      predict4x4(bDcPred, dst, 0, 4, 0, above, 0, left, 0);
      // sum=360, +4 =364, >>3 = 45
      for (int i = 0; i < 16; i++) {
        expect(dst[i], 45);
      }
    });

    test('B_VE row 0 matches H/I/J/K/L/M AVG3 pattern', () {
      const h = 5;
      final above = Uint8List.fromList([10, 20, 30, 40, 50, 0, 0, 0]);
      final dst = _zeros(16);
      predict4x4(bVePred, dst, 0, 4, h, above, 0, _zeros(4), 0);
      final exp = [
        _avg3(h, 10, 20),
        _avg3(10, 20, 30),
        _avg3(20, 30, 40),
        _avg3(30, 40, 50),
      ];
      for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
          expect(dst[r * 4 + c], exp[c]);
        }
      }
    });

    test('B_HE row r matches AVG3 with corner replication on last row', () {
      const h = 5;
      final left = Uint8List.fromList([10, 20, 30, 40]);
      final dst = _zeros(16);
      predict4x4(bHePred, dst, 0, 4, h, _zeros(8), 0, left, 0);
      final exp = [
        _avg3(h, 10, 20),
        _avg3(10, 20, 30),
        _avg3(20, 30, 40),
        _avg3(30, 40, 40),
      ];
      for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
          expect(dst[r * 4 + c], exp[r]);
        }
      }
    });

    test('B_TM is left + above - top_left, clamped', () {
      const tl = 100;
      final above = Uint8List.fromList([110, 120, 130, 140, 0, 0, 0, 0]);
      final left = Uint8List.fromList([90, 95, 100, 105]);
      final dst = _zeros(16);
      predict4x4(bTmPred, dst, 0, 4, tl, above, 0, left, 0);
      for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
          final v = left[r] + above[c] - tl;
          final exp = v < 0 ? 0 : (v > 255 ? 255 : v);
          expect(dst[r * 4 + c], exp);
        }
      }
    });

    test('B_LD anti-diagonal (d45e) corner pixel = AVG3(G,H,H)', () {
      final above =
          Uint8List.fromList([10, 20, 30, 40, 50, 60, 70, 80]); // A..H
      final dst = _zeros(16);
      predict4x4(bLdPred, dst, 0, 4, 0, above, 0, _zeros(4), 0);
      // DST(3,3) = AVG3(G,H,H) = AVG3(70,80,80) = (70 + 160 + 80 + 2)/4 = 78
      expect(dst[3 * 4 + 3], 78);
      // DST(0,0) = AVG3(A,B,C) = (10 + 40 + 30 + 2)/4 = 20
      expect(dst[0], 20);
    });

    test('B_RD diagonal (d135) main diagonal = AVG3(A,X,I)', () {
      const x = 100;
      final above = Uint8List.fromList([110, 120, 130, 140, 0, 0, 0, 0]);
      final left = Uint8List.fromList([90, 80, 70, 60]);
      final dst = _zeros(16);
      predict4x4(bRdPred, dst, 0, 4, x, above, 0, left, 0);
      // main diagonal (0,0),(1,1),(2,2),(3,3) = AVG3(A,X,I) = AVG3(110,100,90) = (110+200+90+2)/4 = 100
      expect(dst[0 * 4 + 0], 100);
      expect(dst[1 * 4 + 1], 100);
      expect(dst[2 * 4 + 2], 100);
      expect(dst[3 * 4 + 3], 100);
    });

    test('B_HU spot-check d207 layout', () {
      final left = Uint8List.fromList([10, 20, 30, 40]);
      final dst = _zeros(16);
      predict4x4(bHuPred, dst, 0, 4, 0, _zeros(8), 0, left, 0);
      // DST(0,0) = AVG2(I,J) = AVG2(10,20) = 15
      expect(dst[0], 15);
      // Bottom-right cluster fills with L=40
      expect(dst[3 * 4 + 3], 40);
      expect(dst[3 * 4 + 0], 40);
      expect(dst[3 * 4 + 1], 40);
      expect(dst[3 * 4 + 2], 40);
      expect(dst[2 * 4 + 2], 40);
      expect(dst[2 * 4 + 3], 40);
    });

    test('B_VL spot-check d63e', () {
      final above =
          Uint8List.fromList([10, 20, 30, 40, 50, 60, 70, 80]); // A..H
      final dst = _zeros(16);
      predict4x4(bVlPred, dst, 0, 4, 0, above, 0, _zeros(4), 0);
      // DST(0,0) = AVG2(A,B) = 15
      expect(dst[0], 15);
      // DST(3,2) = AVG3(E,F,G) = AVG3(50,60,70) = (50+120+70+2)/4 = 60
      expect(dst[2 * 4 + 3], 60);
      // DST(3,3) = AVG3(F,G,H) = AVG3(60,70,80) = (60+140+80+2)/4 = 70
      expect(dst[3 * 4 + 3], 70);
    });

    test('B_VR spot-check d117', () {
      const x = 100;
      final above = Uint8List.fromList([110, 120, 130, 140, 0, 0, 0, 0]);
      final left = Uint8List.fromList([90, 80, 70, 60]);
      final dst = _zeros(16);
      predict4x4(bVrPred, dst, 0, 4, x, above, 0, left, 0);
      // DST(0,0) = AVG2(X,A) = AVG2(100,110) = 105
      expect(dst[0], 105);
      // DST(1,2) = AVG2(X,A) = 105 (shares with (0,0))
      expect(dst[2 * 4 + 1], 105);
    });

    test('B_HD spot-check d153', () {
      const x = 100;
      final above = Uint8List.fromList([110, 120, 130, 0, 0, 0, 0, 0]);
      final left = Uint8List.fromList([90, 80, 70, 60]);
      final dst = _zeros(16);
      predict4x4(bHdPred, dst, 0, 4, x, above, 0, left, 0);
      // DST(0,0) = AVG2(I,X) = AVG2(90,100) = 95
      expect(dst[0], 95);
      // DST(2,1) = AVG2(I,X) = 95 (shares)
      expect(dst[1 * 4 + 2], 95);
      // DST(3,0) = AVG3(A,B,C) = AVG3(110,120,130) = (110+240+130+2)/4 = 120
      expect(dst[0 * 4 + 3], 120);
    });
  });

  group('8x8 chroma', () {
    test('V_PRED replicates 8 above samples', () {
      final dst = _zeros(8 * 8);
      final above = Uint8List.fromList(List.generate(8, (i) => 20 + i * 10));
      predict8x8(vPred, dst, 0, 8, above, 0, _zeros(8), 0, 0, true, true);
      for (int r = 0; r < 8; r++) {
        for (int c = 0; c < 8; c++) {
          expect(dst[r * 8 + c], above[c]);
        }
      }
    });

    test('DC_PRED both available count=16', () {
      final above = _fill(8, 80);
      final left = _fill(8, 40);
      final dst = _zeros(8 * 8);
      predict8x8(dcPred, dst, 0, 8, above, 0, left, 0, 0, true, true);
      // sum = 80*8 + 40*8 = 960; (960 + 8)/16 = 60
      for (int i = 0; i < 64; i++) {
        expect(dst[i], 60);
      }
    });
  });

  test('predict16x16 honours non-zero dst offset and stride', () {
    // Embed an 18x18 buffer (1-pixel border), write to interior (off=18+1).
    final dst = Uint8List(18 * 18);
    final above = _fill(16, 200);
    final left = _zeros(16);
    predict16x16(vPred, dst, 18 + 1, 18, above, 0, left, 0, 0, true, false);
    // First written row at byte offset 19..34
    for (int c = 0; c < 16; c++) {
      expect(dst[19 + c], 200);
    }
    // Border pixels remain zero
    expect(dst[0], 0);
    expect(dst[18], 0); // start of row 1, column 0
  });
}
