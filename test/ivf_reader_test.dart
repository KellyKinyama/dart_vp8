import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

void main() {
  group('IvfReader', () {
    Uint8List buildIvf({
      int fourcc = fourccVp8,
      int width = 320,
      int height = 240,
      List<List<int>> frames = const [],
    }) {
      final out = BytesBuilder();
      final hdr = ByteData(32);
      hdr.setUint8(0, 0x44); // 'D'
      hdr.setUint8(1, 0x4B); // 'K'
      hdr.setUint8(2, 0x49); // 'I'
      hdr.setUint8(3, 0x46); // 'F'
      hdr.setUint16(4, 0, Endian.little); // version
      hdr.setUint16(6, 32, Endian.little); // header length
      hdr.setUint32(8, fourcc, Endian.little);
      hdr.setUint16(12, width, Endian.little);
      hdr.setUint16(14, height, Endian.little);
      hdr.setUint32(16, 1000, Endian.little); // tb den
      hdr.setUint32(20, 30, Endian.little); // tb num
      hdr.setUint32(24, frames.length, Endian.little);
      out.add(hdr.buffer.asUint8List());

      for (var i = 0; i < frames.length; i++) {
        final f = frames[i];
        final fh = ByteData(12);
        fh.setUint32(0, f.length, Endian.little);
        fh.setUint64(4, i, Endian.little);
        out.add(fh.buffer.asUint8List());
        out.add(f);
      }
      return out.toBytes();
    }

    test('parses file header', () {
      final bytes = buildIvf();
      final r = IvfReader(bytes);
      expect(r.header.isVp8, isTrue);
      expect(r.header.width, equals(320));
      expect(r.header.height, equals(240));
      expect(r.header.timebaseNumerator, equals(30));
      expect(r.header.timebaseDenominator, equals(1000));
      expect(r.header.frameCount, equals(0));
      expect(r.nextFrame(), isNull);
    });

    test('reads frames with payload + pts', () {
      final f0 = List<int>.generate(17, (i) => i & 0xff);
      final f1 = List<int>.generate(40, (i) => (i * 7) & 0xff);
      final bytes = buildIvf(frames: [f0, f1]);
      final r = IvfReader(bytes);

      final a = r.nextFrame()!;
      expect(a.pts, equals(0));
      expect(a.data, equals(f0));

      final b = r.nextFrame()!;
      expect(b.pts, equals(1));
      expect(b.data, equals(f1));

      expect(r.nextFrame(), isNull);
    });

    test('rejects bad signature', () {
      final bytes = Uint8List(32);
      // 'XXXX' instead of 'DKIF'.
      bytes[0] = 0x58;
      bytes[1] = 0x58;
      bytes[2] = 0x58;
      bytes[3] = 0x58;
      expect(() => IvfReader(bytes), throwsFormatException);
    });

    test('rejects truncated buffer', () {
      expect(() => IvfReader(Uint8List(10)), throwsFormatException);
    });

    test('rejects truncated frame payload', () {
      final bytes = buildIvf(
        frames: [
          [1, 2, 3, 4, 5],
        ],
      );
      // Chop off some payload bytes.
      final truncated = Uint8List.sublistView(bytes, 0, bytes.length - 3);
      final r = IvfReader(truncated);
      expect(r.nextFrame, throwsFormatException);
    });
  });
}
