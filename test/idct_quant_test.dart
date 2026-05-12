import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

void main() {
  group('idct4x4Add', () {
    test('all-zero input leaves prediction unchanged', () {
      final input = Int16List(16);
      final pred = Uint8List.fromList(List<int>.generate(16, (i) => 10 + i));
      final dst = Uint8List(16);
      idct4x4Add(input, 0, pred, 0, 4, dst, 0, 4);
      expect(dst, equals(pred));
    });

    test('DC-only path matches full IDCT', () {
      // For an input with only coef[0] non-zero, both forms must agree.
      const int dc = 80;
      final input = Int16List(16)..[0] = dc;
      final pred =
          Uint8List.fromList(List<int>.generate(16, (i) => (i * 13) & 0xff));
      final dstFull = Uint8List(16);
      final dstDc = Uint8List(16);

      idct4x4Add(input, 0, pred, 0, 4, dstFull, 0, 4);
      dcOnlyIdct4x4Add(dc, pred, 0, 4, dstDc, 0, 4);
      expect(dstFull, equals(dstDc));
    });

    test('clamps output to [0, 255]', () {
      final input = Int16List(16);
      input[0] = 4096; // DC contribution = 512
      final pred = Uint8List.fromList(List<int>.filled(16, 200));
      final dst = Uint8List(16);
      idct4x4Add(input, 0, pred, 0, 4, dst, 0, 4);
      for (final v in dst) {
        expect(v, equals(255));
      }
    });

    test('DC contribution rounds correctly (full path)', () {
      final input = Int16List(16);
      input[0] = 8;
      final pred = Uint8List.fromList(List<int>.filled(16, 128));
      final dst = Uint8List(16);
      idct4x4Add(input, 0, pred, 0, 4, dst, 0, 4);
      for (final v in dst) {
        expect(v, equals(129));
      }
    });

    test('DC-only contribution rounds correctly', () {
      // dc=8 => (8+4)>>3 = 1, added to mid-gray.
      final pred = Uint8List.fromList(List<int>.filled(16, 128));
      final dst = Uint8List(16);
      dcOnlyIdct4x4Add(8, pred, 0, 4, dst, 0, 4);
      for (final v in dst) {
        expect(v, equals(129));
      }
    });
  });

  group('inverseWalsh4x4', () {
    test('DC-only IWHT equals fast path', () {
      const int dc = 100;
      final input = Int16List(16)..[0] = dc;
      final viaFull = Int16List(16 * 16);
      final viaFast = Int16List(16 * 16);

      inverseWalsh4x4(input, 0, viaFull, 0);
      inverseWalsh4x4Dc(dc, viaFast, 0);
      expect(viaFull, equals(viaFast));
      // ((100 + 3) >> 3) == 12.
      for (int i = 0; i < 16; i++) {
        expect(viaFast[i * 16], equals(12));
      }
    });

    test('scatters into block DC slots only', () {
      // Pick an input with a few nonzero entries; just verify that all
      // non-DC slots in qcoeff remain zero.
      final input = Int16List(16);
      input[0] = 32;
      input[3] = 16;
      input[10] = -8;
      final dq = Int16List(16 * 16);
      inverseWalsh4x4(input, 0, dq, 0);
      for (int i = 0; i < 16; i++) {
        for (int j = 1; j < 16; j++) {
          expect(dq[i * 16 + j], equals(0));
        }
      }
    });
  });

  group('dequant tables', () {
    test('boundary lookups match libvpx', () {
      expect(yAcQuant(0), equals(4));
      expect(yAcQuant(127), equals(284));
      expect(yDcQuant(0, 0), equals(4));
      expect(yDcQuant(127, 0), equals(157));
      expect(uvDcQuant(127, 0), equals(132)); // capped
      // y2_ac floor.
      expect(y2AcQuant(0, 0), equals(8));
    });

    test('qindex clamps deltas', () {
      expect(yDcQuant(0, -50), equals(yDcQuant(0, 0)));
      expect(yDcQuant(120, 100), equals(yDcQuant(127, 0)));
    });

    test('buildDequant returns expected struct', () {
      final dq = buildDequant(
        qi: 40,
        y1DcDelta: 0,
        y2DcDelta: 0,
        y2AcDelta: 0,
        uvDcDelta: 0,
        uvAcDelta: 0,
      );
      expect(dq.y1Ac, equals(acQLookup[40]));
      expect(dq.y2Dc, equals(dcQLookup[40] * 2));
    });
  });
}
