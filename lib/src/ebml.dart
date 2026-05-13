// Minimal EBML (Extensible Binary Meta Language) primitives, sufficient
// for parsing WebM container streams. EBML is the Matroska/WebM
// foundation: every file is a tree of (id, length, payload) elements
// where both id and length are variable-length integers.
//
// Spec: https://datatracker.ietf.org/doc/html/rfc8794
//
// We support only what WebM-VP8 needs:
//   - VINT-encoded element IDs (kept in their "with marker" form so we
//     can compare against the raw constants in webm_reader.dart).
//   - VINT-encoded sizes (with the marker bit stripped); 0xFF (1-byte
//     "unknown size") is rejected — WebM in the wild always sets sizes,
//     and supporting unknown-size is meaningfully more complex.
//   - Big-endian unsigned integer payloads (1..8 bytes).
//   - String / binary payloads (returned as Uint8List sublist views).
//
// All parsing is zero-copy: buffers are sublist views into the original
// input.

import 'dart:typed_data';

/// One EBML element header: ID, size, and the absolute byte offset where
/// the payload starts.
class EbmlElement {
  EbmlElement(this.id, this.size, this.payloadOffset);

  /// Element ID with its leading marker bit kept (matches WebM spec
  /// constants, e.g. 0x1A45DFA3 for the EBML header).
  final int id;

  /// Payload length in bytes.
  final int size;

  /// Absolute byte offset of the first payload byte in the source buffer.
  final int payloadOffset;

  /// Absolute byte offset of the first byte AFTER this element.
  int get end => payloadOffset + size;
}

/// Random-access EBML element scanner over an in-memory buffer.
class EbmlReader {
  EbmlReader(this.bytes) : _bd = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData _bd;

  /// Read an EBML VINT starting at [offset]. Returns the decoded value
  /// and the number of bytes consumed. If [stripMarker] is true, the
  /// most-significant marker bit is cleared (size encoding); otherwise
  /// the marker bit is kept (ID encoding).
  ({int value, int length}) readVint(int offset, {required bool stripMarker}) {
    if (offset >= bytes.length) {
      throw const FormatException('EBML: vint read past end of buffer');
    }
    final int first = bytes[offset];
    if (first == 0) {
      throw const FormatException('EBML: vint with no length marker');
    }
    int length = 1;
    int mask = 0x80;
    while ((first & mask) == 0) {
      length++;
      mask >>= 1;
    }
    if (length > 8) {
      throw FormatException('EBML: vint length $length > 8');
    }
    if (offset + length > bytes.length) {
      throw const FormatException('EBML: vint truncated');
    }
    int value = stripMarker ? (first & (mask - 1)) : first;
    for (int i = 1; i < length; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return (value: value, length: length);
  }

  /// Parse one EBML element header at [offset]. Throws on truncation or
  /// unknown-size elements.
  EbmlElement readElement(int offset) {
    final id = readVint(offset, stripMarker: false);
    final size = readVint(offset + id.length, stripMarker: true);
    // Per spec, all-ones VINT means "unknown size" (streamable). We
    // don't handle that — every WebM file produced by real muxers
    // (ffmpeg, libwebm) writes definite sizes.
    final int sizeMaxForLen = (1 << (7 * size.length)) - 1;
    if (size.value == sizeMaxForLen) {
      throw const FormatException('EBML: unknown-size elements not supported');
    }
    final payloadOffset = offset + id.length + size.length;
    if (payloadOffset + size.value > bytes.length) {
      throw const FormatException('EBML: element extends past buffer');
    }
    return EbmlElement(id.value, size.value, payloadOffset);
  }

  /// Streaming-friendly variant of [readElement]: returns null instead
  /// of throwing if either the header or the payload would extend past
  /// the end of the currently-available buffer. Still throws for
  /// genuinely malformed VINTs and unknown-size elements.
  EbmlElement? tryReadElement(int offset) {
    if (offset >= bytes.length) return null;
    // Check ID VINT length is fully present.
    final int first = bytes[offset];
    if (first == 0) {
      throw const FormatException('EBML: vint with no length marker');
    }
    int idLen = 1;
    int mask = 0x80;
    while ((first & mask) == 0) {
      idLen++;
      mask >>= 1;
    }
    if (idLen > 8) {
      throw FormatException('EBML: vint length $idLen > 8');
    }
    if (offset + idLen > bytes.length) return null;
    // Check size VINT length is fully present.
    final int sizeOff = offset + idLen;
    if (sizeOff >= bytes.length) return null;
    final int sFirst = bytes[sizeOff];
    if (sFirst == 0) {
      throw const FormatException('EBML: vint with no length marker');
    }
    int sLen = 1;
    int sMask = 0x80;
    while ((sFirst & sMask) == 0) {
      sLen++;
      sMask >>= 1;
    }
    if (sLen > 8) {
      throw FormatException('EBML: vint length $sLen > 8');
    }
    if (sizeOff + sLen > bytes.length) return null;
    // Decode size to know the full element extent.
    final int sizeMaxForLen = (1 << (7 * sLen)) - 1;
    int sizeVal = sFirst & (sMask - 1);
    for (int i = 1; i < sLen; i++) {
      sizeVal = (sizeVal << 8) | bytes[sizeOff + i];
    }
    if (sizeVal == sizeMaxForLen) {
      throw const FormatException('EBML: unknown-size elements not supported');
    }
    final int payloadOff = sizeOff + sLen;
    if (payloadOff + sizeVal > bytes.length) return null;
    return readElement(offset);
  }

  /// Read a payload as an unsigned big-endian integer (1..8 bytes).
  /// Per the spec, an empty payload represents 0.
  int readUint(EbmlElement e) {
    if (e.size == 0) return 0;
    if (e.size > 8) {
      throw FormatException('EBML: uint payload ${e.size}>8 bytes');
    }
    int v = 0;
    for (int i = 0; i < e.size; i++) {
      v = (v << 8) | bytes[e.payloadOffset + i];
    }
    return v;
  }

  /// Read a payload as a big-endian IEEE-754 float (4 or 8 bytes).
  double readFloat(EbmlElement e) {
    if (e.size == 0) return 0.0;
    if (e.size == 4) return _bd.getFloat32(e.payloadOffset);
    if (e.size == 8) return _bd.getFloat64(e.payloadOffset);
    throw FormatException('EBML: float payload ${e.size} bytes (need 4 or 8)');
  }

  /// Read a payload as a UTF-8 / ASCII string (used for CodecID, DocType).
  String readString(EbmlElement e) {
    // Strip trailing NULs (spec allows zero-padded strings).
    int n = e.size;
    while (n > 0 && bytes[e.payloadOffset + n - 1] == 0) {
      n--;
    }
    return String.fromCharCodes(bytes, e.payloadOffset, e.payloadOffset + n);
  }

  /// Return a zero-copy view of an element's payload bytes.
  Uint8List bin(EbmlElement e) =>
      Uint8List.sublistView(bytes, e.payloadOffset, e.end);

  /// Iterate the children of a master element, yielding each child's
  /// header. Skips into the payload and advances by each child's length.
  Iterable<EbmlElement> children(EbmlElement parent) sync* {
    int off = parent.payloadOffset;
    final int end = parent.end;
    while (off < end) {
      final child = readElement(off);
      yield child;
      off = child.end;
    }
  }
}
