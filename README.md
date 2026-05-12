# dart_vp8

Pure-Dart VP8 video decoder (RFC 6386). Correctness-focused reference port; no
SIMD, no real-time guarantees.

Status: **work in progress.** See the staged plan in the source tree:

| Stage | Module                                          | Status |
| ----- | ----------------------------------------------- | ------ |
| 1     | IVF reader + boolean (range) decoder            | done   |
| 2     | Frame header / segmentation / quant / probs     | todo   |
| 3     | Token decoding + dequant + IWHT/IDCT 4x4        | todo   |
| 4     | Intra prediction (16x16, 8x8 UV, 4x4 luma)      | todo   |
| 5     | Inter prediction (6-tap subpel + bilinear)      | todo   |
| 6     | Loop filter (normal + simple)                   | todo   |
| 7     | Top-level decoder glue + public API             | todo   |

Spec: <https://datatracker.ietf.org/doc/html/rfc6386>
