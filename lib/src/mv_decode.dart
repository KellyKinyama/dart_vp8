// VP8 MV decoding: read_mvcomponent, read_mv. Direct port of the
// `read_mvcomponent` / `read_mv` pair in vp8/decoder/decodemv.c.
//
// The MV context is a Uint8List of 19 probabilities per component (row
// then column) laid out as:
//   [0]      is-short
//   [1]      sign
//   [2..8]   short-magnitude tree probs (7)
//   [9..18]  long-magnitude bit probs (10)

import 'bool_decoder.dart';
import 'constants/mode_mv_probs.dart';
import 'mv.dart';
import 'tree.dart';

/// Decode one MV component (row OR column) in 1/4-pel units.
/// `mvc` is the full 38-byte two-context array; `ctxOff` is 0 (row) or 19
/// (column).
int readMvComponent(BoolDecoder bc, List<int> mvc, int ctxOff) {
  int x;

  if (bc.read(mvc[ctxOff + mvpIsShort]) != 0) {
    // Long magnitude.
    x = 0;
    for (int i = 0; i < 3; i++) {
      x += bc.read(mvc[ctxOff + mvpBits + i]) << i;
    }
    // libvpx skips bit 3 in this loop and reads it last (only sometimes).
    for (int i = mvlongWidth - 1; i > 3; i--) {
      x += bc.read(mvc[ctxOff + mvpBits + i]) << i;
    }
    if ((x & 0xFFF0) == 0 || bc.read(mvc[ctxOff + mvpBits + 3]) != 0) {
      x += 8;
    }
  } else {
    // Short magnitude (0..7) via vp8_small_mvtree.
    final probs = <int>[
      mvc[ctxOff + mvpShort],
      mvc[ctxOff + mvpShort + 1],
      mvc[ctxOff + mvpShort + 2],
      mvc[ctxOff + mvpShort + 3],
      mvc[ctxOff + mvpShort + 4],
      mvc[ctxOff + mvpShort + 5],
      mvc[ctxOff + mvpShort + 6],
    ];
    x = treeDecode(bc, vp8SmallMvTree, probs);
  }

  if (x != 0 && bc.read(mvc[ctxOff + mvpSign]) != 0) {
    x = -x;
  }
  return x;
}

/// Read both MV components and return an `Mv` in 1/8-pel units.
Mv readMv(BoolDecoder bc, List<int> mvc) {
  final int row = readMvComponent(bc, mvc, 0) * 2;
  final int col = readMvComponent(bc, mvc, mvpCount) * 2;
  return Mv(row, col);
}
