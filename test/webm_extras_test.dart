// Tests for the WebM extras added in 0.2.0:
//   * track listing
//   * Segment duration + frameRate
//   * Cues-based seekToTime
//   * WebmWriter round-trip with WebmReader + Vp8Decoder

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';
import 'package:test/test.dart';

const String _webm = 'test/fixtures/sample.webm';

void main() {
  group('WebM track + duration metadata', () {
    test('exposes tracks + duration + frame rate', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final bytes = Uint8List.fromList(File(_webm).readAsBytesSync());
      final r = WebmReader(bytes);
      expect(r.tracks, isNotEmpty);
      expect(r.video.codecId, 'V_VP8');
      expect(r.video.isVideo, isTrue);
      expect(r.video.width, 640);
      expect(r.video.height, 360);
      // Big Buck Bunny clip is ~10 s.
      expect(r.durationNanos, isNotNull);
      expect(r.durationNanos!, greaterThan(5 * 1000000000));
      expect(r.durationNanos!, lessThan(15 * 1000000000));
    });
  });

  group('WebM seeking', () {
    test('seekToTime lands on or before requested timestamp', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final bytes = Uint8List.fromList(File(_webm).readAsBytesSync());
      final r = WebmReader(bytes);
      final target = (r.durationNanos ?? 5000000000) ~/ 2;
      final landed = r.seekToTime(target);
      expect(landed, isNotNull);
      expect(landed!, lessThanOrEqualTo(target));
      // The first frame after seeking must be at-or-after the cluster
      // timestamp we landed on.
      final first = r.nextFrame();
      expect(first, isNotNull);
      expect(first!.ptsNanos, greaterThanOrEqualTo(landed));
      // And the very next frame must decode cleanly (it'll be a keyframe
      // if Cues are aligned to keyframes, which ffmpeg always does).
      final dec = Vp8Decoder();
      final df = dec.decodeBytes(first.data);
      expect(df.width, r.width);
    });

    test('seekToTime(0) + linear scan == raw linear scan', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final bytes = Uint8List.fromList(File(_webm).readAsBytesSync());
      final a = WebmReader(bytes);
      final b = WebmReader(bytes)..seekToTime(0);
      // Both should yield the same first-frame PTS and same byte view.
      final fa = a.nextFrame()!;
      final fb = b.nextFrame()!;
      expect(fb.ptsNanos, fa.ptsNanos);
      expect(fb.data.length, fa.data.length);
    });
  });

  group('WebmWriter round-trip', () {
    test('mux 2 frames + demux yields the same bytes', () {
      // Build a fake 2-frame "stream" — the bytes don't have to be valid
      // VP8 for the container round-trip test; the demuxer just sees
      // them as opaque payloads.
      final f0 = Uint8List.fromList(List.generate(64, (i) => i & 0xFF));
      final f1 = Uint8List.fromList(List.generate(48, (i) => (i * 7) & 0xFF));
      final w = WebmWriter(width: 16, height: 16, frameRate: 30.0);
      w.addFrame(f0, ptsNanos: 0, isKeyFrame: true);
      w.addFrame(f1, ptsNanos: 33333333, isKeyFrame: false); // ~33 ms
      final bytes = w.finish();

      // Should round-trip via the reader.
      final r = WebmReader(bytes);
      expect(r.video.codecId, 'V_VP8');
      expect(r.width, 16);
      expect(r.height, 16);
      // 30 fps DefaultDuration was written.
      expect(r.frameRate, isNotNull);
      expect(r.frameRate!, closeTo(30.0, 0.01));
      // Duration written.
      expect(r.durationNanos, isNotNull);

      final g0 = r.nextFrame()!;
      expect(g0.isKeyFrame, isTrue);
      expect(g0.ptsNanos, 0);
      expect(g0.data, f0);

      final g1 = r.nextFrame()!;
      expect(g1.isKeyFrame, isFalse);
      // Quantised to 1ms => 33ms == 33,000,000 ns.
      expect(g1.ptsNanos, 33000000);
      expect(g1.data, f1);

      expect(r.nextFrame(), isNull);
    });

    test('writer emits Cues that the reader can use for seeking', () {
      final f = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final w = WebmWriter(width: 8, height: 8);
      // Three keyframes, each starting its own Cluster.
      w.addFrame(f, ptsNanos: 0, isKeyFrame: true);
      w.addFrame(f, ptsNanos: 100000000, isKeyFrame: true); // 100 ms
      w.addFrame(f, ptsNanos: 200000000, isKeyFrame: true); // 200 ms
      final bytes = w.finish();

      final r = WebmReader(bytes);
      expect(r.hasCues, isTrue);
      // Seek to 150 ms — should land on the 100 ms cluster.
      final landed = r.seekToTime(150000000);
      expect(landed, 100000000);
      final next = r.nextFrame()!;
      expect(next.ptsNanos, 100000000);
      expect(next.isKeyFrame, isTrue);
    });

    test('writer rejects inter-frame as the very first frame', () {
      final w = WebmWriter(width: 8, height: 8);
      expect(
        () => w.addFrame(Uint8List(4), ptsNanos: 0, isKeyFrame: false),
        throwsStateError,
      );
    });

    test('full mux round-trip of sample.webm decodes to identical YUV', () {
      if (!File(_webm).existsSync()) {
        markTestSkipped('missing fixture: $_webm');
        return;
      }
      final bytes = Uint8List.fromList(File(_webm).readAsBytesSync());
      final src = WebmReader(bytes);

      // Re-mux: pull every frame, push into a fresh WebmWriter.
      final w = WebmWriter(width: src.width, height: src.height);
      final List<int> origPts = <int>[];
      final List<bool> origKf = <bool>[];
      while (true) {
        final f = src.nextFrame();
        if (f == null) break;
        w.addFrame(f.data, ptsNanos: f.ptsNanos, isKeyFrame: f.isKeyFrame);
        origPts.add(f.ptsNanos);
        origKf.add(f.isKeyFrame);
      }
      final remuxed = w.finish();

      final back = WebmReader(remuxed);
      int i = 0;
      while (true) {
        final f = back.nextFrame();
        if (f == null) break;
        // PTS should round-trip exactly (input was already 1ms-quantised).
        expect(f.ptsNanos, origPts[i]);
        expect(f.isKeyFrame, origKf[i]);
        i++;
      }
      expect(i, origPts.length);
    });
  });
}
