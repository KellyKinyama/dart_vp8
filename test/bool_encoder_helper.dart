// Reference VP8 boolean encoder, used only by tests to validate the decoder
// via round-trip. Mirrors RFC 6386 §7.3 exactly.

import 'dart:typed_data';

class BoolEncoder {
  final List<int> _out = <int>[];
  int _range = 255;
  int _bottom = 0; // 32-bit working register
  int _bitCount = 24;

  void _addOneToOutput() {
    int i = _out.length - 1;
    while (i >= 0 && _out[i] == 0xff) {
      _out[i] = 0;
      i--;
    }
    if (i >= 0) _out[i] = (_out[i] + 1) & 0xff;
  }

  void write(int bit, int prob) {
    final int split = 1 + (((_range - 1) * prob) >> 8);
    if (bit != 0) {
      _bottom += split;
      _range -= split;
    } else {
      _range = split;
    }
    while (_range < 128) {
      _range <<= 1;
      if ((_bottom & 0x80000000) != 0) {
        _addOneToOutput();
      }
      _bottom = (_bottom << 1) & 0xffffffff;
      _bitCount--;
      if (_bitCount == 0) {
        _out.add((_bottom >> 24) & 0xff);
        _bottom &= 0xffffff;
        _bitCount = 8;
      }
    }
  }

  void writeLiteral(int value, int bits) {
    for (int i = bits - 1; i >= 0; i--) {
      write((value >> i) & 1, 128);
    }
  }

  Uint8List finish() {
    // Flush remaining bits.
    for (int i = 0; i < 32; i++) {
      write(0, 128);
    }
    return Uint8List.fromList(_out);
  }
}
