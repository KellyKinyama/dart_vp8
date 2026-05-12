// Border-padded reference frame for inter prediction.
//
// VP8 inter prediction (6-tap subpel and bilinear) reads up to 2 samples
// outside the block on the top/left and 3 on the bottom/right. When MVs
// point near (or past) the frame edge, the read positions extend beyond
// the picture. libvpx solves this by allocating each reference Y/U/V plane
// with a `border` of padding pixels on every side and replicating the
// edge samples after each frame is decoded (`vp8_yv12_extend_frame_borders`).
//
// We mirror that approach: allocate `(width + 2*border) * (height + 2*border)`
// per plane, and offer `copyFromCanonical` that fills the padding rows /
// columns from the nearest interior sample.
//
// Border size: 32 luma pixels is what libvpx uses; we follow suit.

import 'dart:typed_data';

const int yBorder = 32;
const int uvBorder = 16;

class RefFrame {
  RefFrame({
    required this.width,
    required this.height,
  })  : yStride = ((width + 15) & ~15) + 2 * yBorder,
        uvStride = (((width + 15) & ~15) >> 1) + 2 * uvBorder {
    final int yH = ((height + 15) & ~15) + 2 * yBorder;
    final int uvH = (((height + 15) & ~15) >> 1) + 2 * uvBorder;
    y = Uint8List(yStride * yH);
    u = Uint8List(uvStride * uvH);
    v = Uint8List(uvStride * uvH);
  }

  /// Cropped frame width / height (not including padding).
  final int width;
  final int height;

  /// Byte stride of Y plane, including left+right border.
  final int yStride;

  /// Byte stride of each chroma plane, including left+right border.
  final int uvStride;

  late final Uint8List y;
  late final Uint8List u;
  late final Uint8List v;

  /// Byte offset of (row=0, col=0) of the visible Y picture.
  int get yOrigin => yBorder * yStride + yBorder;

  /// Byte offset of (row=0, col=0) of the visible U/V picture.
  int get uvOrigin => uvBorder * uvStride + uvBorder;
}

/// Copy a cropped, tightly-stride-padded source plane into `dst` at the
/// origin, then replicate the four edges and four corners into the border.
void _planeCopyWithBorders({
  required Uint8List src,
  required int srcStride,
  required int srcWidth,
  required int srcHeight,
  required Uint8List dst,
  required int dstStride,
  required int border,
}) {
  // Copy visible region.
  final int dstOrigin = border * dstStride + border;
  for (int r = 0; r < srcHeight; r++) {
    final int sRow = r * srcStride;
    final int dRow = dstOrigin + r * dstStride;
    for (int c = 0; c < srcWidth; c++) {
      dst[dRow + c] = src[sRow + c];
    }
  }

  // Left/right edges: replicate first and last interior column.
  for (int r = 0; r < srcHeight; r++) {
    final int dRow = dstOrigin + r * dstStride;
    final int leftSample = dst[dRow];
    final int rightSample = dst[dRow + srcWidth - 1];
    for (int c = -border; c < 0; c++) {
      dst[dRow + c] = leftSample;
    }
    for (int c = srcWidth; c < srcWidth + border; c++) {
      dst[dRow + c] = rightSample;
    }
  }

  // Top edge: replicate row 0 of (now-extended) interior.
  for (int r = -border; r < 0; r++) {
    final int dRow = dstOrigin + r * dstStride;
    final int srcDRow = dstOrigin;
    for (int c = -border; c < srcWidth + border; c++) {
      dst[dRow + c] = dst[srcDRow + c];
    }
  }
  // Bottom edge: replicate row (srcHeight-1).
  for (int r = srcHeight; r < srcHeight + border; r++) {
    final int dRow = dstOrigin + r * dstStride;
    final int srcDRow = dstOrigin + (srcHeight - 1) * dstStride;
    for (int c = -border; c < srcWidth + border; c++) {
      dst[dRow + c] = dst[srcDRow + c];
    }
  }
}

/// Fill a [RefFrame] from canonical (no-border) Y/U/V planes.
void refFrameFromPlanes({
  required RefFrame dst,
  required Uint8List srcY,
  required int srcYStride,
  required Uint8List srcU,
  required Uint8List srcV,
  required int srcUvStride,
}) {
  // MB-aligned dims (matches what the decoder allocates).
  final int yW = (dst.width + 15) & ~15;
  final int yH = (dst.height + 15) & ~15;
  final int uvW = yW >> 1;
  final int uvH = yH >> 1;

  _planeCopyWithBorders(
    src: srcY,
    srcStride: srcYStride,
    srcWidth: yW,
    srcHeight: yH,
    dst: dst.y,
    dstStride: dst.yStride,
    border: yBorder,
  );
  _planeCopyWithBorders(
    src: srcU,
    srcStride: srcUvStride,
    srcWidth: uvW,
    srcHeight: uvH,
    dst: dst.u,
    dstStride: dst.uvStride,
    border: uvBorder,
  );
  _planeCopyWithBorders(
    src: srcV,
    srcStride: srcUvStride,
    srcWidth: uvW,
    srcHeight: uvH,
    dst: dst.v,
    dstStride: dst.uvStride,
    border: uvBorder,
  );
}

/// Shallow copy: makes [dst] alias [src] (same Uint8List backing). Used by
/// the copy-buffer-to-gf/arf machinery to avoid pointless allocation. The
/// caller must ensure [dst] is not subsequently mutated; for a true clone
/// use [cloneRefFrame].
RefFrame? aliasRefFrame(RefFrame? src) => src;

/// Deep copy of a reference frame: allocates new Y/U/V buffers and copies
/// all bytes (including borders) verbatim.
RefFrame cloneRefFrame(RefFrame src) {
  final dst = RefFrame(width: src.width, height: src.height);
  dst.y.setAll(0, src.y);
  dst.u.setAll(0, src.u);
  dst.v.setAll(0, src.v);
  return dst;
}
