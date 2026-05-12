import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main() {
  final ivfBytes = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.ivf')
      .readAsBytesSync();
  final ref = File(
          'c:/www/dart/libvpx/dart_vp8/test/fixtures/vp80-00-comprehensive-001.yuv')
      .readAsBytesSync();
  final reader = IvfReader(Uint8List.fromList(ivfBytes));
  final dec = Vp8Decoder();
  for (int i = 0; i < 3; i++) {
    final df = dec.decode(reader.nextFrame()!);
    if (i == 2) {
      final fOff = 2 * 38016;
      // Scan all diffs in Y plane.
      final diffs = <int>[];
      for (int b = 0; b < 176 * 144; b++) {
        final r = b ~/ 176;
        final c = b % 176;
        if (df.y[r * df.yStride + c] != ref[fOff + b]) {
          diffs.add(b);
        }
      }
      print('Total Y diffs in frame 2: ${diffs.length}');
      // Group by MB.
      final byMb = <String, int>{};
      for (final b in diffs) {
        final r = b ~/ 176;
        final c = b % 176;
        final key = 'MB(${r ~/ 16},${c ~/ 16})';
        byMb[key] = (byMb[key] ?? 0) + 1;
      }
      print('Diffs per MB:');
      final sorted = byMb.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in sorted.take(20)) {
        print('  ${e.key}: ${e.value}');
      }
      // Show first 30 diff locations.
      print('First 30 diff locations (r,c) dart→ref:');
      for (final b in diffs.take(30)) {
        final r = b ~/ 176;
        final c = b % 176;
        print(
            '  r=$r c=$c MB(${r ~/ 16},${c ~/ 16}) dart=${df.y[r * df.yStride + c]} ref=${ref[fOff + b]}');
      }
    }
  }
}
