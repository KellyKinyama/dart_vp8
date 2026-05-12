// Port of ivfdec.c (libvpx) to Dart. IVF is the trivial container used by
// libvpx's test harness: a 32-byte file header followed by, per frame, a
// 12-byte frame header and the raw compressed payload. All multi-byte fields
// are little-endian.
//
// Reference: libvpx/ivfdec.c

import 'dart:typed_data';

/// Four-character code 'VP80'.
const int fourccVp8 = 0x30385056;

/// Four-character code 'VP90'.
const int fourccVp9 = 0x30395056;

/// Maximum allowed compressed-frame size (matches libvpx's 256 MiB sanity cap).
const int _maxFrameSize = 256 * 1024 * 1024;

/// IVF file-level header (the first 32 bytes of an IVF stream).
class IvfFileHeader {
  IvfFileHeader({
    required this.version,
    required this.fourcc,
    required this.width,
    required this.height,
    required this.timebaseNumerator,
    required this.timebaseDenominator,
    required this.frameCount,
  });

  final int version;
  final int fourcc;
  final int width;
  final int height;
  final int timebaseNumerator;
  final int timebaseDenominator;
  final int frameCount;

  bool get isVp8 => fourcc == fourccVp8;
}

/// One decoded IVF frame: timestamp (PTS in timebase units) and payload bytes.
class IvfFrame {
  IvfFrame(this.pts, this.data);
  final int pts;
  final Uint8List data;
}

/// Reads frames out of an in-memory IVF byte buffer.
///
/// IVF was chosen as the Stage-1 container because it has no external
/// dependencies (unlike WebM) and is the format used by libvpx's own test
/// vectors.
class IvfReader {
  IvfReader._(this._bytes, this._bd, this.header, this._offset);

  /// Parse the 32-byte file header and return a reader positioned at the
  /// first frame. Throws [FormatException] if the signature is wrong or the
  /// buffer is truncated.
  factory IvfReader(Uint8List bytes) {
    if (bytes.length < 32) {
      throw const FormatException('IVF: buffer shorter than file header');
    }
    final bd = ByteData.sublistView(bytes);
    // Signature: 'DKIF'.
    if (bytes[0] != 0x44 ||
        bytes[1] != 0x4B ||
        bytes[2] != 0x49 ||
        bytes[3] != 0x46) {
      throw const FormatException('IVF: missing DKIF signature');
    }
    final version = bd.getUint16(4, Endian.little);
    // libvpx only warns on non-zero versions; we accept them.
    final headerLen = bd.getUint16(6, Endian.little);
    if (headerLen < 32) {
      throw FormatException('IVF: header length $headerLen < 32');
    }
    final fourcc = bd.getUint32(8, Endian.little);
    final width = bd.getUint16(12, Endian.little);
    final height = bd.getUint16(14, Endian.little);
    final tbDen = bd.getUint32(16, Endian.little);
    final tbNum = bd.getUint32(20, Endian.little);
    final frameCount = bd.getUint32(24, Endian.little);
    // bytes 28..31 reserved.

    final header = IvfFileHeader(
      version: version,
      fourcc: fourcc,
      width: width,
      height: height,
      // Note: IVF stores denominator first then numerator; we expose them in
      // the conventional num/den orientation.
      timebaseNumerator: tbNum,
      timebaseDenominator: tbDen,
      frameCount: frameCount,
    );
    return IvfReader._(bytes, bd, header, headerLen);
  }

  final Uint8List _bytes;
  final ByteData _bd;
  int _offset;

  final IvfFileHeader header;

  /// Returns the next frame, or null at end-of-stream.
  IvfFrame? nextFrame() {
    if (_offset >= _bytes.length) return null;
    if (_offset + 12 > _bytes.length) {
      throw const FormatException('IVF: truncated frame header');
    }
    final size = _bd.getUint32(_offset, Endian.little);
    final pts = _bd.getUint64(_offset + 4, Endian.little);
    _offset += 12;

    if (size > _maxFrameSize) {
      throw FormatException('IVF: frame size $size exceeds sanity cap');
    }
    if (_offset + size > _bytes.length) {
      throw const FormatException('IVF: truncated frame payload');
    }
    final data = Uint8List.sublistView(_bytes, _offset, _offset + size);
    _offset += size;
    return IvfFrame(pts, data);
  }
}
