# dart_vp8

Pure-Dart VP8 video decoder ([RFC 6386]). Correctness-focused reference
port of the upstream `libvpx` decoder; no SIMD, no platform plugins, no
`dart:io` dependency in the library.

[RFC 6386]: https://datatracker.ietf.org/doc/html/rfc6386

## Status

**Functionally complete.** All 62 official VP8 conformance vectors from
`libvpx`'s `kVP8TestVectors` list decode **byte-exact** against the
upstream reference (MD5 of the raw I420 output, every frame, every
vector):

| Suite                       | Vectors | Status |
| --------------------------- | ------: | ------ |
| `vp80-00-comprehensive`     |      18 | ✔ pass |
| `vp80-01-intra`             |       4 | ✔ pass |
| `vp80-02-inter`             |       4 | ✔ pass |
| `vp80-03-segmentation`     |      22 | ✔ pass |
| `vp80-04-partitions`        |       3 | ✔ pass |
| `vp80-05-sharpness`         |      10 | ✔ pass |
| `vp80-06-smallsize`         |       1 | ✔ pass |
| **Total**                   |  **62** | ✔ pass |

Plus 14 robustness tests covering malformed / truncated / corrupt input.

## Features

- Pure Dart, zero runtime dependencies.
- Decodes any conforming VP8 stream: key + inter frames, all four MV
  partitionings (16x16, 16x8, 8x16, 4x4 SPLITMV), B_PRED intra, multi-
  token-partition (1 / 2 / 4 / 8), full segmentation with per-segment
  Q / LF deltas, normal + simple loop filter at all sharpness levels,
  hidden reference frames (`show_frame=0`).
- Includes a minimal IVF demuxer and a WebM/Matroska demuxer (V_VP8
  video tracks); use `Vp8Reader` to auto-detect either container.
- Library imports only `dart:typed_data` — runs on the VM, AOT, and
  Flutter Web.

## Performance

Indicative AOT throughput on a single core (`dart compile exe`):

| Vector                                     | Resolution |   FPS |
| ------------------------------------------ | ---------- | ----: |
| `vp80-00-comprehensive-013` (small)        | 176x144    | ~1500 |
| `vp80-01-intra-1411` (intra-only)          | 320x240    |  ~600 |
| `vp80-00-comprehensive-014` (SPLITMV-rich) | 176x144    |  ~575 |

This is a correctness reference, not a production codec — expect a
hardware decoder or `libvpx` itself to be roughly an order of magnitude
faster.

## Usage

```yaml
dependencies:
  dart_vp8: ^0.1.0
```

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_vp8/dart_vp8.dart';

void main(List<String> args) {
  final bytes = Uint8List.fromList(File(args.single).readAsBytesSync());
  // Auto-detects IVF (.ivf) or WebM (.webm) from the magic bytes.
  final reader = Vp8Reader(bytes);
  final decoder = Vp8Decoder();

  while (true) {
    final pkt = reader.nextPacket();
    if (pkt == null) break;
    final out = decoder.decodeBytes(pkt.data);
    if (!out.isShown) continue; // hidden / alt-ref reference

    // out.y, out.u, out.v are Uint8List planes at strides
    // out.yStride and out.uvStride. Crop to out.width x out.height.
    print('${out.width}x${out.height} '
        '(${out.isKeyFrame ? "kf" : "inter"})');
  }
}
```

The returned `Uint8List` planes alias the decoder's internal buffers
and are overwritten on the next `decode()` call; copy them out if you
need to keep them around.

## API surface

The high-level entry points live at the top of the library:

- `Vp8Reader` / `Vp8Packet` — container-agnostic demuxer (IVF or WebM).
- `IvfReader` / `IvfFrame` — IVF-only demuxer.
- `WebmReader` / `WebmFrame` — WebM/Matroska V_VP8 demuxer.
- `Vp8Decoder` — stateful decoder; one instance per stream.
- `DecodedFrame` — decoded I420 output (Y, U, V planes + metadata).

Lower-level primitives (boolean decoder, frame header parser, IDCT,
intra / inter predictors, loop filter, etc.) are also exported so they
can be exercised in isolation by tests; most callers do not need them.

## Testing

```bash
dart test                                  # full suite (~6 s)
dart test test/conformance_suite_test.dart # 62 conformance vectors
dart test test/robustness_test.dart        # malformed-input fuzz
```

The 62 conformance `.ivf` / `.ivf.md5` fixtures live under
`test/fixtures/`. Fetch them with:

```bash
bash tool/fetch_vectors.sh
```

(downloads ~3 MB from
`storage.googleapis.com/downloads.webmproject.org/test_data/libvpx`).

## Benchmarking

```bash
dart compile exe bin/bench.dart -o bin/bench.exe
./bin/bench.exe test/fixtures/vp80-00-comprehensive-014.ivf 20
```

## Non-goals

- VP8 encoder.
- VP9 / AV1 decoders.
- MP4 demuxer (use a separate package — WebM is supported in-tree).
- Audio decoding (Vorbis / Opus). The WebM demuxer ignores audio tracks.
- Hardware acceleration / SIMD.
- Real-time playback guarantees.

## License

BSD-3-Clause, matching upstream `libvpx`. The reference C source this
project ports from is `libvpx`
(<https://chromium.googlesource.com/webm/libvpx>), copyright the WebM
project authors.
