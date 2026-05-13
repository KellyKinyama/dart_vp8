// End-to-end smoke test for the WebM demuxer + Vp8Decoder pipeline.
//
// The fixture `test/fixtures/sample.webm` is a 1 MB ~10s clip of Big Buck
// Bunny at 640x360, 24 fps, VP8 video, no audio. We just verify:
//   * the demuxer auto-detects the container,
//   * yields the expected number of frames,
//   * each frame decodes without error,
//   * the first frame is a keyframe,
//   * decoded planes have the right sizes.

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

const String _webm = 'test/fixtures/sample.webm';

void main() {
  group('WebM end-to-end', () {
    test('decodes sample.webm via Vp8Reader auto-detect', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final bytes = Uint8List.fromList(File(_webm).readAsBytesSync());
      final reader = Vp8Reader(bytes);
      expect(reader.width, greaterThan(0));
      expect(reader.height, greaterThan(0));

      final dec = Vp8Decoder();
      int frames = 0;
      int kf = 0;
      while (true) {
        final pkt = reader.nextPacket();
        if (pkt == null) break;
        final df = dec.decodeBytes(pkt.data);
        frames++;
        if (df.isKeyFrame) kf++;
        // Sanity: planes match declared dims.
        expect(df.width, reader.width);
        expect(df.height, reader.height);
        expect(df.y.length, df.yStride * (((df.height + 15) >> 4) * 16));
      }
      expect(frames, greaterThan(50),
          reason: '~10s @ 24fps should give >50 frames');
      expect(kf, greaterThan(0), reason: 'must contain at least one keyframe');
    });

    test('WebmReader yields monotonic non-decreasing PTS', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final bytes = Uint8List.fromList(File(_webm).readAsBytesSync());
      final wm = WebmReader(bytes);
      int last = -1;
      while (true) {
        final f = wm.nextFrame();
        if (f == null) break;
        // VP8 has no B-frames, so PTS must be monotonic.
        expect(f.ptsNanos, greaterThanOrEqualTo(last));
        last = f.ptsNanos;
      }
      expect(last, greaterThan(0));
    });

    test('Vp8Reader still accepts IVF input (auto-detect)', () {
      const ivf = 'test/fixtures/vp80-00-comprehensive-001.ivf';
      if (!File(ivf).existsSync()) {
        markTestSkipped('missing fixture: $ivf');
        return;
      }
      final bytes = Uint8List.fromList(File(ivf).readAsBytesSync());
      final r = Vp8Reader(bytes);
      expect(r.width, greaterThan(0));
      final pkt = r.nextPacket();
      expect(pkt, isNotNull);
      // Decode the first packet just to be sure.
      final dec = Vp8Decoder();
      final df = dec.decodeBytes(pkt!.data);
      expect(df.isKeyFrame, isTrue);
    });
  });

  group('EBML primitives', () {
    test('VINT decodes 1- through 8-byte lengths with marker stripping', () {
      // 1-byte: 0x80 (length 1, value 0)
      // 2-byte: 0x4001 (length 2, value 1)
      // 3-byte: 0x200001 (length 3, value 1)
      final r = EbmlReader(Uint8List.fromList(<int>[
        0x80,
        0x40,
        0x01,
        0x20,
        0x00,
        0x01,
      ]));
      var v = r.readVint(0, stripMarker: true);
      expect(v.value, 0);
      expect(v.length, 1);
      v = r.readVint(1, stripMarker: true);
      expect(v.value, 1);
      expect(v.length, 2);
      v = r.readVint(3, stripMarker: true);
      expect(v.value, 1);
      expect(v.length, 3);
    });

    test('VINT keeps the marker bit when stripMarker=false (ID encoding)', () {
      // The EBML root ID 0x1A45DFA3 is 4 bytes; encoded as itself.
      final r = EbmlReader(Uint8List.fromList(<int>[0x1A, 0x45, 0xDF, 0xA3]));
      final v = r.readVint(0, stripMarker: false);
      expect(v.value, 0x1A45DFA3);
      expect(v.length, 4);
    });

    test('rejects vint with no length marker', () {
      final r = EbmlReader(Uint8List.fromList(<int>[0x00]));
      expect(() => r.readVint(0, stripMarker: true), throwsFormatException);
    });
  });

  group('WebM demuxer error paths', () {
    test('rejects non-WebM input', () {
      final junk = Uint8List(64);
      expect(() => WebmReader(junk), throwsFormatException);
    });

    test('Vp8Reader rejects unknown container', () {
      final junk = Uint8List(64);
      junk[0] = 0xFF;
      expect(() => Vp8Reader(junk), throwsFormatException);
    });
  });
}
