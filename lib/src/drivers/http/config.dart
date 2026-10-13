import 'package:shared_api/src/core/http/compression.dart';

class HttpConfig {
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
  final Map<String, String>? headers;
  final List<int>? certificates;
  final Map<String, String> services;

  /// Request body compression, e.g.
  /// `RequestCompression(GzipCompressor(), threshold: 1024)`.
  /// Null (default) disables it: the backend must accept the encoding.
  final RequestCompression? compression;

  const HttpConfig({
    this.connectTimeout = const Duration(seconds: 30),
    this.sendTimeout = const Duration(seconds: 30),
    this.receiveTimeout = const Duration(seconds: 30),
    this.headers,
    this.certificates,
    this.services = const {},
    this.compression,
  });

  factory HttpConfig.initial() {
    return const HttpConfig();
  }
}
