import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

import 'bool_encoder_helper.dart';

void main() {
  group('BoolDecoder', () {
    test('decodes uniform 50/50 bit stream', () {
      // Encode a known bit pattern with prob=128 (uniform), then decode.
      final pattern = <int>[
        1,
        0,
        1,
        1,
        0,
        0,
        1,
        0,
        1,
        1,
        1,
        0,
        0,
        1,
        0,
        1,
        1,
        1,
        0,
        0,
        1,
        1,
        0,
        1,
        0,
        1,
        0,
        0,
        1,
        1,
        1,
        0,
      ];
      final enc = BoolEncoder();
      for (final b in pattern) {
        enc.write(b, 128);
      }
      final bytes = enc.finish();

      final dec = BoolDecoder(bytes);
      for (var i = 0; i < pattern.length; i++) {
        expect(dec.read(128), equals(pattern[i]), reason: 'bit $i');
      }
      expect(dec.error, isFalse);
    });

    test('decodes biased probabilities', () {
      // Mix probabilities to exercise the renorm path with non-trivial splits.
      final pattern = <int>[];
      final probs = <int>[];
      var rng = 0x12345678;
      for (var i = 0; i < 5000; i++) {
        // xorshift32 for deterministic test data.
        rng ^= (rng << 13) & 0xffffffff;
        rng ^= (rng >> 17) & 0xffffffff;
        rng ^= (rng << 5) & 0xffffffff;
        final p = 1 + (rng & 0xfd); // 1..254
        // Decide the actual bit using a second draw, weighted to exercise both.
        final draw = (rng >> 8) & 0xff;
        final bit = draw < p ? 0 : 1;
        probs.add(p);
        pattern.add(bit);
      }
      final enc = BoolEncoder();
      for (var i = 0; i < pattern.length; i++) {
        enc.write(pattern[i], probs[i]);
      }
      final bytes = enc.finish();

      final dec = BoolDecoder(bytes);
      for (var i = 0; i < pattern.length; i++) {
        expect(
          dec.read(probs[i]),
          equals(pattern[i]),
          reason: 'bit $i (prob=${probs[i]})',
        );
      }
      expect(dec.error, isFalse);
    });

    test('readLiteral round-trips raw bits', () {
      final enc = BoolEncoder();
      enc.writeLiteral(0xA5, 8);
      enc.writeLiteral(0x1234, 16);
      enc.writeLiteral(0x7F, 7);
      final bytes = enc.finish();

      final dec = BoolDecoder(bytes);
      expect(dec.readLiteral(8), equals(0xA5));
      expect(dec.readLiteral(16), equals(0x1234));
      expect(dec.readLiteral(7), equals(0x7F));
    });

    test('readTree decodes a simple 4-symbol tree', () {
      // Balanced binary tree over 4 symbols:
      //   node 0 -> {bit=0: node 2, bit=1: node 4}
      //   node 2 -> {bit=0: -0,     bit=1: -1}
      //   node 4 -> {bit=0: -2,     bit=1: -3}
      final tree = <int>[2, 4, -0, -1, -2, -3];
      final probs = <int>[200, 100, 50]; // one per internal node

      // Encode the path for each symbol and verify.
      for (var sym = 0; sym < 4; sym++) {
        final enc = BoolEncoder();
        // Path for sym: top bit selects subtree, low bit selects leaf.
        final topBit = sym >> 1;
        final lowBit = sym & 1;
        enc.write(topBit, probs[0]);
        enc.write(lowBit, probs[topBit == 0 ? 1 : 2]);
        final bytes = enc.finish();

        final dec = BoolDecoder(bytes);
        expect(dec.readTree(tree, probs), equals(sym), reason: 'symbol $sym');
      }
    });

    test('error flag set when reading past end', () {
      final dec = BoolDecoder(Uint8List.fromList(<int>[0x00, 0x00]));
      // Drain a lot of bits; the buffer has only 2 bytes.
      for (var i = 0; i < 200; i++) {
        dec.read(128);
      }
      expect(dec.error, isTrue);
    });
  });
}
