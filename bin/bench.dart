// Decode the largest available conformance vector N times in AOT and
// report frames/sec. Used to track perf regressions across changes.

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final path = args.isNotEmpty
      ? args.first
      : 'test/fixtures/vp80-00-comprehensive-018.ivf';
  final iterations = args.length > 1 ? int.parse(args[1]) : 5;

  final ivf = File(path).readAsBytesSync();
  print('vector: $path  size=${ivf.length} bytes');

  // Warmup.
  _decodeOnce(Uint8List.fromList(ivf));

  int totalFrames = 0;
  final sw = Stopwatch()..start();
  for (int i = 0; i < iterations; i++) {
    totalFrames += _decodeOnce(Uint8List.fromList(ivf));
  }
  sw.stop();
  final ms = sw.elapsedMicroseconds / 1000.0;
  final fps = totalFrames * 1000.0 / ms;
  print('iters=$iterations  frames=$totalFrames  '
      'wall=${ms.toStringAsFixed(1)}ms  '
      'fps=${fps.toStringAsFixed(1)}  '
      'per-frame=${(ms / totalFrames).toStringAsFixed(3)}ms');
}

int _decodeOnce(Uint8List bytes) {
  final r = IvfReader(bytes);
  final dec = Vp8Decoder();
  int frames = 0;
  while (true) {
    final f = r.nextFrame();
    if (f == null) break;
    final df = dec.decode(f);
    if (df.isShown) frames++;
  }
  return frames;
}
