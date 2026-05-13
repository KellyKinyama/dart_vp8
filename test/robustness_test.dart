// Robustness tests: feed the decoder malformed/truncated/garbage input and
// verify it fails with a clean Dart exception (no crash, no infinite loop,
// no out-of-bounds typed-data access). The decoder is allowed to either
// throw FormatException or RangeError; what is NOT allowed is silently
// returning corrupt output or hanging.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

const String _vec = 'test/fixtures/vp80-00-comprehensive-001.ivf';

Uint8List _readFirstFramePayload() {
  final ivf = File(_vec).readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivf));
  return reader.nextFrame()!.data;
}

void main() {
  group('IVF reader robustness', () {
    test('rejects empty input', () {
      expect(() => IvfReader(Uint8List(0)), throwsFormatException);
    });

    test('rejects bad signature', () {
      final b = Uint8List(64);
      b[0] = 0x42; // 'B' instead of 'D'
      expect(() => IvfReader(b), throwsFormatException);
    });

    test('rejects header_len < 32', () {
      final b = Uint8List(32);
      b[0] = 0x44; b[1] = 0x4B; b[2] = 0x49; b[3] = 0x46; // DKIF
      // header_len=8 at offset 6 (little-endian u16)
      b[6] = 8; b[7] = 0;
      expect(() => IvfReader(b), throwsFormatException);
    });

    test('rejects truncated frame header', () {
      // Build a valid file header plus 5 bytes of frame data.
      final fh = Uint8List(32);
      fh[0] = 0x44; fh[1] = 0x4B; fh[2] = 0x49; fh[3] = 0x46;
      fh[6] = 32; fh[7] = 0;
      final b = Uint8List(37)..setRange(0, 32, fh);
      final r = IvfReader(b);
      expect(r.nextFrame, throwsFormatException);
    });

    test('rejects insanely large frame size', () {
      final fh = Uint8List(32);
      fh[0] = 0x44; fh[1] = 0x4B; fh[2] = 0x49; fh[3] = 0x46;
      fh[6] = 32; fh[7] = 0;
      final b = Uint8List(32 + 12);
      b.setRange(0, 32, fh);
      // size = 0xFFFFFFFF
      b[32] = 0xFF; b[33] = 0xFF; b[34] = 0xFF; b[35] = 0xFF;
      final r = IvfReader(b);
      expect(r.nextFrame, throwsFormatException);
    });
  });

  group('Vp8Decoder header robustness', () {
    test('rejects empty payload', () {
      final dec = Vp8Decoder();
      expect(() => dec.decode(IvfFrame(0, Uint8List(0))),
          throwsA(isA<Exception>()));
    });

    test('rejects 2-byte payload', () {
      final dec = Vp8Decoder();
      expect(() => dec.decode(IvfFrame(0, Uint8List.fromList([0, 0]))),
          throwsA(isA<Exception>()));
    });

    test('rejects keyframe with wrong sync code', () {
      // 3-byte VP8 frame tag with key_frame bit (low bit of byte 0 = 0
      // means key_frame), plus 4 bytes for width/height/start codes.
      // Use a bogus sync code.
      final b = Uint8List(16);
      // first_part_size encoded in upper 19 bits of 24-bit tag — use 8.
      // tag = (size << 5) | (version << 1) | key_flag(0)
      b[0] = (8 << 5) & 0xff;
      b[1] = 0;
      b[2] = 0;
      // bogus sync
      b[3] = 0x00; b[4] = 0x00; b[5] = 0x00;
      b[6] = 0x10; b[7] = 0x00; // width=16
      b[8] = 0x10; b[9] = 0x00; // height=16
      final dec = Vp8Decoder();
      expect(() => dec.decode(IvfFrame(0, b)), throwsFormatException);
    });

    test('rejects inter frame before any keyframe', () {
      // tag with key_flag=1 (inter)
      final b = Uint8List(64);
      b[0] = (8 << 5) | 1;
      final dec = Vp8Decoder();
      expect(() => dec.decode(IvfFrame(0, b)), throwsA(isA<Exception>()));
    });

    test('rejects truncated keyframe (cuts off sync/dimensions)', () {
      final b = Uint8List(5); // < 10 bytes for a keyframe
      b[0] = (8 << 5) & 0xff; // key flag = 0
      final dec = Vp8Decoder();
      expect(() => dec.decode(IvfFrame(0, b)), throwsFormatException);
    });

    test('rejects keyframe whose first-partition runs past end', () {
      // Encode a partition size larger than the buffer.
      final b = Uint8List(20);
      // first_part_size = 1000 (way more than 20-10 bytes available)
      const size = 1000;
      b[0] = ((size << 5) & 0xff);
      b[1] = ((size >> 3) & 0xff);
      b[2] = ((size >> 11) & 0xff);
      b[3] = 0x9D; b[4] = 0x01; b[5] = 0x2A; // sync
      b[6] = 0x10; b[7] = 0x00; b[8] = 0x10; b[9] = 0x00;
      final dec = Vp8Decoder();
      expect(() => dec.decode(IvfFrame(0, b)), throwsFormatException);
    });
  });

  group('Vp8Decoder corrupted-payload robustness', () {
    test('flips one byte in the middle of the first partition', () {
      // Take a real frame, corrupt one byte near the start of the bool-coded
      // first partition, ensure decode either throws or returns without
      // crashing the VM. We don't care about output validity here.
      final payload = _readFirstFramePayload();
      // Walk a handful of byte positions to cover several decode paths.
      for (final offset in const [10, 20, 50, 100]) {
        if (offset >= payload.length) continue;
        final bad = Uint8List.fromList(payload);
        bad[offset] ^= 0xFF;
        final dec = Vp8Decoder();
        try {
          dec.decode(IvfFrame(0, bad));
          // Returning normally is acceptable — the decoder may interpret
          // the corruption as valid (lower-entropy) bits.
        } on Exception catch (_) {
          // Throwing is also acceptable.
        }
      }
    });

    test('truncates the payload to half its length', () {
      final payload = _readFirstFramePayload();
      final half = Uint8List.sublistView(payload, 0, payload.length ~/ 2);
      final dec = Vp8Decoder();
      // Either throws or returns; must not hang or crash the VM.
      try {
        dec.decode(IvfFrame(0, half));
      } on Exception catch (_) {}
    });

    test('random garbage of various lengths', () {
      final rng = Random(0xC0DEFEED);
      for (final len in const [16, 64, 256, 1024, 4096]) {
        final b = Uint8List(len);
        for (int i = 0; i < len; i++) {
          b[i] = rng.nextInt(256);
        }
        final dec = Vp8Decoder();
        try {
          dec.decode(IvfFrame(0, b));
        } on Exception catch (_) {}
      }
    });
  });
}
