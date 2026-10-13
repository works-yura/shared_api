import 'dart:convert';
import 'dart:io' show HttpHeaders;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_api/src/core/http/compression.dart';

/// Compresses request bodies larger than [threshold] bytes with [compressor]
/// and sets `Content-Encoding` accordingly.
///
/// Leaves the request untouched when:
/// - running on Web (the browser controls the transport);
/// - there is no body, or it is [FormData] / another unsupported type;
/// - the caller already set `Content-Encoding` (body is pre-encoded);
/// - a Map/List body is not sent as JSON (e.g. form-urlencoded);
/// - compression does not make the body smaller;
/// - compression fails (fail-safe: original body is sent).
///
/// Response decompression is not handled here: dart:io decodes gzip
/// responses itself.
class CompressionInterceptor extends Interceptor {
  final RequestCompressor compressor;

  /// Bodies of at most this many bytes are sent uncompressed.
  final int threshold;

  CompressionInterceptor({
    required this.compressor,
    this.threshold = 1024,
  });

  /// Builds an interceptor from [RequestCompression] settings.
  CompressionInterceptor.fromSettings(RequestCompression settings)
      : this(compressor: settings.compressor, threshold: settings.threshold);

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (kIsWeb || _isAlreadyEncoded(options)) return handler.next(options);

    try {
      final bytes = _bodyBytes(options);
      if (bytes != null && bytes.length > threshold) {
        final compressed = compressor.compress(bytes);
        if (compressed.length < bytes.length) {
          options.data = Uint8List.fromList(compressed);
          options.headers[HttpHeaders.contentEncodingHeader] =
              compressor.encoding;
        }
      }
    } catch (_) {
      // Fail-safe: send the original body.
    }

    handler.next(options);
  }

  bool _isAlreadyEncoded(RequestOptions options) => options.headers.keys.any(
      (k) => k.toLowerCase() == HttpHeaders.contentEncodingHeader);

  /// Serialized body bytes, or null when the body must not be compressed.
  List<int>? _bodyBytes(RequestOptions options) {
    final data = options.data;
    if (data is List<int>) return data;
    if (data is String) return utf8.encode(data);
    if ((data is Map || data is List) && _isJson(options)) {
      return utf8.encode(jsonEncode(data));
    }
    return null;
  }

  bool _isJson(RequestOptions options) {
    final contentType = options.contentType;
    return contentType == null || Transformer.isJsonMimeType(contentType);
  }
}
