# Changelog

## 0.2.1

- Documentation and metadata polish; no functional changes since 0.2.0.
- Verified all 198 tests pass.

## 0.2.0

- WebM demuxer: full track listing (`tracks`, `WebmTrack`), Segment
  duration, video frame rate from `DefaultDuration`.
- WebM demuxer: Cues-based `seekToTime(int nanos)` (binary-searched);
  falls back to a linear cluster scan when no Cues are present.
- New `WebmWriter` that muxes a sequence of VP8 frames into a valid
  .webm file (one Cluster per keyframe, Cues emitted at the tail).
- New `WebmStreamReader` for incremental / chunked input — `addBytes`
  pushes more data, `nextFrame` returns null until enough bytes have
  arrived.
- New `EbmlReader.tryReadElement` non-throwing variant for streaming.
- Robustness: 7 new fuzz / corruption tests for the WebM parser.

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
