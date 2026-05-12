// VP8 boolean (binary arithmetic / range) decoder.
//
// Faithful port of the reference algorithm in RFC 6386 §7
// ("Boolean Entropy Decoder"). libvpx's production decoder
// (vp8/decoder/dboolhuff.c) uses a wider value register for speed; we use the
// reference 16-bit-window form because it is simpler, byte-portable, and
// works identically on the Dart VM and on dart2js (where ints are doubles).
// Bit-exactness with libvpx is preserved.

import 'dart:typed_data';

/// VP8 boolean (range) decoder.
class BoolDecoder {
  /// Initialize over [buffer]. Reads the first two bytes immediately, matching
  /// `InitBoolDecoder` in RFC 6386 §7.
  BoolDecoder(Uint8List buffer) : _buf = buffer, _bufLen = buffer.length {
    if (_bufLen >= 1) {
      _value = _buf[0] << 8;
      _bufPos = 1;
    }
    if (_bufLen >= 2) {
      _value |= _buf[1];
      _bufPos = 2;
    }
  }

  final Uint8List _buf;
  final int _bufLen;
  int _bufPos = 0;

  /// Current range; always in [128, 255] after each `read`.
  int _range = 255;

  /// Current value window.
  int _value = 0;

  /// Bits shifted out of the value register since the last byte refill (0..7).
  int _bitCount = 0;

  bool _error = false;

  /// True once a read consumed bits past the end of the buffer.
  bool get error => _error;

  /// Decode one boolean with probability [prob] (0..255) that the bit is 0.
  /// Returns 0 or 1.
  int read(int prob) {
    final int split = 1 + (((_range - 1) * prob) >> 8);
    final int splitHi = split << 8;
    int result;
    if (_value >= splitHi) {
      result = 1;
      _range -= split;
      _value -= splitHi;
    } else {
      result = 0;
      _range = split;
    }
    while (_range < 128) {
      _value <<= 1;
      _range <<= 1;
      _bitCount++;
      if (_bitCount == 8) {
        _bitCount = 0;
        if (_bufPos < _bufLen) {
          _value |= _buf[_bufPos];
          _bufPos++;
        } else {
          _error = true;
        }
      }
    }
    return result;
  }

  /// Read [bits] raw bits (each with probability 128), MSB first.
  int readLiteral(int bits) {
    int v = 0;
    for (int i = bits - 1; i >= 0; i--) {
      v |= read(128) << i;
    }
    return v;
  }

  /// Read [bits] then negate if the following sign bit is set.
  int readSignedLiteral(int bits) {
    final int mag = readLiteral(bits);
    final int sign = read(128);
    return sign != 0 ? -mag : mag;
  }

  /// Read a VP8 tree-coded symbol. [tree] is laid out as in libvpx: at
  /// internal node i, the child for bit b is `tree[i + b]`; non-positive
  /// values are leaves and the decoded symbol is `-tree[i + b]`. [probs]
  /// supplies a probability for each internal node, indexed by `i >> 1`.
  int readTree(List<int> tree, List<int> probs) {
    int i = 0;
    while (true) {
      final int b = read(probs[i >> 1]);
      final int v = tree[i + b];
      if (v <= 0) return -v;
      i = v;
    }
  }
}
