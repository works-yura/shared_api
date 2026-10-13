/// Compresses HTTP request bodies for one `Content-Encoding`.
///
/// Implement this to add a format (e.g. `br`, `zstd`) or a custom one:
///
/// ```dart
/// class ZstdCompressor extends RequestCompressor {
///   const ZstdCompressor();
///
///   @override
///   String get encoding => 'zstd';
///
///   @override
///   List<int> compress(List<int> bytes) => zstd.encode(bytes);
/// }
/// ```
abstract class RequestCompressor {
  const RequestCompressor();

  /// Value sent in the `Content-Encoding` header (e.g. `gzip`).
  String get encoding;

  /// Returns the compressed form of [bytes].
  List<int> compress(List<int> bytes);
}

/// Request body compression settings.
///
/// The backend must accept the chosen `Content-Encoding`.
class RequestCompression {
  /// Format used to compress request bodies.
  final RequestCompressor compressor;

  /// Bodies of at most this many bytes are sent uncompressed.
  final int threshold;

  const RequestCompression(this.compressor, {this.threshold = 1024});
}
