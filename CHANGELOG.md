# Changelog

## 0.1.0

Initial public release.

- Pure-Dart VP8 decoder (RFC 6386). Byte-exact on all 62 official VP8
  conformance vectors (`vp80-00` through `vp80-06`).
- IVF demuxer (`IvfReader`) and WebM/Matroska VP8 demuxer (`WebmReader`).
- Container auto-detect via `Vp8Reader` (IVF or WebM).
- 14 robustness tests covering truncated, oversized, and malformed inputs.
- AOT throughput baseline: ~600 fps for intra-only 320x240 on a desktop CPU.
- No `dart:io` in the library; runs on Dart VM, AOT and Flutter Web.
- Example: `example/decode_to_ppm.dart` decodes any IVF/WebM file to a PPM
  image sequence.
