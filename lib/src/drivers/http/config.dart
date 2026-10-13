import 'package:shared_api/src/core/http/compression.dart';

class HttpConfig {
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
  final Map<String, String>? headers;

  /// Trusted certificates (PEM/DER bytes) for certificate pinning.
  /// When null, the platform trust store is used.
  final List<int>? certificates;

  /// Accepts ANY TLS certificate. Development only (self-signed local
  /// servers): never enable in production, it allows man-in-the-middle.
  final bool allowBadCertificates;
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
    this.allowBadCertificates = false,
    this.services = const {},
    this.compression,
  });

  factory HttpConfig.initial() {
    return const HttpConfig();
  }
}
