// Robustness + streaming tests for the WebM parser. We never want a
// malformed file to crash the host application — every error path
// must surface as a [FormatException] (or a [StateError] for misuse
// of [WebmStreamReader]).

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

const String _webm = 'test/fixtures/sample.webm';

void main() {
  group('WebM corruption robustness', () {
    test('empty buffer', () {
      expect(() => WebmReader(Uint8List(0)), throwsFormatException);
    });

    test('buffer too small to sniff', () {
      expect(() => WebmReader(Uint8List(2)), throwsFormatException);
    });

    test('wrong magic bytes', () {
      final b = Uint8List(64);
      b[0] = 0x00;
      expect(() => WebmReader(b), throwsFormatException);
    });

    test('valid EBML header but no Segment', () {
      // Build just the EBML element (with valid DocType).
      final w = WebmWriter(width: 8, height: 8);
      w.addFrame(Uint8List(4), ptsNanos: 0, isKeyFrame: true);
      final full = w.finish();
      // Truncate immediately after the EBML element. The EBML header in
      // a fresh WebmWriter output is short — find the Segment ID start
      // (0x18 0x53 0x80 0x67) and slice just before it.
      int seg = -1;
      for (int i = 0; i < full.length - 3; i++) {
        if (full[i] == 0x18 &&
            full[i + 1] == 0x53 &&
            full[i + 2] == 0x80 &&
            full[i + 3] == 0x67) {
          seg = i;
          break;
        }
      }
      expect(seg, greaterThan(0));
      final truncated = Uint8List.sublistView(full, 0, seg);
      expect(() => WebmReader(truncated), throwsFormatException);
    });

    test('byte flips in the EBML header are caught', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final original = File(_webm).readAsBytesSync();
      final rng = Random(0xBADF00D);
      int caught = 0;
      for (int trial = 0; trial < 16; trial++) {
        final mut = Uint8List.fromList(original);
        // Corrupt a byte somewhere in the first 256 bytes (header zone).
        final idx = rng.nextInt(256);
        mut[idx] ^= 0xFF;
        try {
          // Even if construction succeeds, draining must not crash.
          final r = WebmReader(mut);
          while (true) {
            final f = r.nextFrame();
            if (f == null) break;
          }
        } on FormatException {
          caught++;
        }
      }
      // Most random flips in the header zone should produce a clean
      // FormatException. Allow some that happen to land on payload bytes
      // and still parse.
      expect(caught, greaterThan(0));
    });

    test('truncated tail does not crash', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final original = File(_webm).readAsBytesSync();
      // Drop the last 1024 bytes — clusters near the tail will be
      // malformed but everything before should still iterate cleanly.
      final cut = Uint8List.sublistView(
          Uint8List.fromList(original), 0, original.length - 1024);
      try {
        final r = WebmReader(cut);
        while (true) {
          final f = r.nextFrame();
          if (f == null) break;
        }
      } on FormatException {
        // Acceptable.
      }
    });

    test('writer rejects negative-or-huge timestamp delta', () {
      final w = WebmWriter(width: 8, height: 8);
      w.addFrame(Uint8List(4), ptsNanos: 0, isKeyFrame: true);
      // 60 seconds without a keyframe — exceeds int16 1ms-scale range.
      expect(
        () => w.addFrame(Uint8List(4),
            ptsNanos: 60 * 1000000000, isKeyFrame: false),
        throwsStateError,
      );
    });
  });

  group('WebM streaming reader', () {
    test('drip-feeds bytes 1 KB at a time and yields all frames', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final all = Uint8List.fromList(File(_webm).readAsBytesSync());
      // Reference: how many frames does the in-memory reader give us?
      final ref = WebmReader(all);
      int refCount = 0;
      while (ref.nextFrame() != null) {
        refCount++;
      }

      final s = WebmStreamReader();
      final frames = <WebmFrame>[];
      const int chunk = 1024;
      for (int i = 0; i < all.length; i += chunk) {
        final end = i + chunk < all.length ? i + chunk : all.length;
        s.addBytes(Uint8List.sublistView(all, i, end));
        // Drain everything that's now decodable.
        while (true) {
          final f = s.nextFrame();
          if (f == null) break;
          frames.add(f);
        }
      }
      s.endOfStream();
      // Flush any tail.
      while (true) {
        final f = s.nextFrame();
        if (f == null) break;
        frames.add(f);
      }
      expect(s.headerReady, isTrue);
      expect(s.video.codecId, 'V_VP8');
      expect(frames.length, refCount);
    });

    test('header is rejected for non-WebM input as soon as enough bytes', () {
      final s = WebmStreamReader();
      s.addBytes(Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF, 0xFF]));
      expect(s.tryParseHeader, throwsFormatException);
    });

    test('headerReady is false until enough bytes have arrived', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final all = File(_webm).readAsBytesSync();
      final s = WebmStreamReader();
      // Feed only 8 bytes — enough to see EBML magic but not enough for
      // the full header.
      s.addBytes(all.sublist(0, 8));
      expect(s.tryParseHeader(), isFalse);
      expect(s.headerReady, isFalse);
      expect(s.nextFrame(), isNull);
    });
  });
}
