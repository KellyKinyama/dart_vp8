// Decode a VP8 video (IVF or WebM) to a sequence of PPM (P6) images.
//
// Usage:
//   dart run example/decode_to_ppm.dart <input.{ivf,webm}> <out_dir> [--max=N]
//
// Each frame is written as `out_dir/frame_NNNNNN.ppm` (binary P6 RGB888).
// PPM is used because it's the simplest lossless format that needs zero
// dependencies — any modern image viewer / ffmpeg / ImageMagick can read
// the result. Convert to PNG with:
//   ffmpeg -i out_dir/frame_%06d.ppm out.mp4
// or:
//   magick out_dir/frame_*.ppm out.gif

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> argv) {
  if (argv.length < 2) {
    stderr.writeln(
        'Usage: dart run example/decode_to_ppm.dart <input> <out_dir> [--max=N]');
    exit(2);
  }
  final input = argv[0];
  final outDir = argv[1];
  int maxFrames = 1 << 30;
  for (final a in argv.skip(2)) {
    if (a.startsWith('--max=')) {
      maxFrames = int.parse(a.substring(6));
    }
  }
  Directory(outDir).createSync(recursive: true);

  final bytes = Uint8List.fromList(File(input).readAsBytesSync());
  final reader = Vp8Reader(bytes);
  stdout.writeln(
      'Input ${reader.width}x${reader.height}, decoding to $outDir/...');

  final dec = Vp8Decoder();
  final sw = Stopwatch()..start();
  int n = 0;
  while (n < maxFrames) {
    final pkt = reader.nextPacket();
    if (pkt == null) break;
    final frame = dec.decodeBytes(pkt.data);
    if (!frame.isShown) continue; // Skip alt-ref / not-shown frames.
    final rgb = _yuv420ToRgb(frame);
    final path = '$outDir/frame_${n.toString().padLeft(6, '0')}.ppm';
    _writePpm(path, frame.width, frame.height, rgb);
    n++;
    if (n % 24 == 0) stdout.write('.');
  }
  sw.stop();
  stdout.writeln();
  stdout.writeln('Wrote $n frame(s) in ${sw.elapsedMilliseconds} ms '
      '(${(n * 1000 / sw.elapsedMilliseconds).toStringAsFixed(1)} fps).');
}

/// BT.601 limited-range YCbCr → RGB conversion. Uses the integer-math
/// coefficients from the JFIF spec, which match what ffmpeg's `yuv2rgb`
/// uses for SDTV content (which is what VP8 web video almost always is).
Uint8List _yuv420ToRgb(DecodedFrame f) {
  final int w = f.width;
  final int h = f.height;
  final out = Uint8List(w * h * 3);
  final Uint8List y = f.y;
  final Uint8List u = f.u;
  final Uint8List v = f.v;
  final int ys = f.yStride;
  final int us = f.uvStride;
  final int vs = f.uvStride;
  int o = 0;
  for (int j = 0; j < h; j++) {
    final int yRow = j * ys;
    final int cRow = (j >> 1);
    final int uRow = cRow * us;
    final int vRow = cRow * vs;
    for (int i = 0; i < w; i++) {
      final int yy = y[yRow + i] - 16;
      final int cb = u[uRow + (i >> 1)] - 128;
      final int cr = v[vRow + (i >> 1)] - 128;
      // Coefficients × 256, rounded.
      int r = (298 * yy + 409 * cr + 128) >> 8;
      int g = (298 * yy - 100 * cb - 208 * cr + 128) >> 8;
      int b = (298 * yy + 516 * cb + 128) >> 8;
      if (r < 0)
        r = 0;
      else if (r > 255) r = 255;
      if (g < 0)
        g = 0;
      else if (g > 255) g = 255;
      if (b < 0)
        b = 0;
      else if (b > 255) b = 255;
      out[o++] = r;
      out[o++] = g;
      out[o++] = b;
    }
  }
  return out;
}

void _writePpm(String path, int w, int h, Uint8List rgb) {
  final f = File(path).openSync(mode: FileMode.write);
  try {
    f.writeStringSync('P6\n$w $h\n255\n');
    f.writeFromSync(rgb);
  } finally {
    f.closeSync();
  }
}
