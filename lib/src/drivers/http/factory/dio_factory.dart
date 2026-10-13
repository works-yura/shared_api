import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import 'package:shared_api/shared_api.dart';

import '../config.dart';

class DioFactory {
  final HttpConfig config;
  final Transformer? transformer;
  final dynamic Function(String)? jsonDecodeCallback;

  DioFactory({
    required this.config,
    this.transformer,
    this.jsonDecodeCallback,
  });

  /// HttpClient that accepts any certificate. Development only.
  static io.HttpClient insecureHttpClient() {
    final client = io.HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }

  Dio create() {
    final dio = Dio();

    // 1. Base Options
    dio.options.connectTimeout = config.connectTimeout;
    dio.options.sendTimeout = config.sendTimeout;
    dio.options.receiveTimeout = config.receiveTimeout;
    // Treat 304 Not Modified as a success so it reaches the response
    // interceptors (CacheInterceptor conditional-GET handler) instead of
    // being thrown as a DioException.
    dio.options.validateStatus = HttpValidator.validateStatus;

    if (config.headers != null) {
      dio.options.headers.addAll(config.headers!);
    }

    // 2. SSL & Platform Config
    if (!kIsWeb) {
      final adapter = dio.httpClientAdapter;
      if (adapter is IOHttpClientAdapter) {
        final certificates = config.certificates;
        if (config.allowBadCertificates) {
          assert(() {
            debugPrint('[DioFactory] WARNING: TLS validation disabled '
                '(allowBadCertificates). Development only.');
            return true;
          }());
          adapter.createHttpClient = insecureHttpClient;
        } else if (certificates != null) {
          // Certificate pinning: trust only the provided certificates.
          adapter.createHttpClient = () {
            final securityContext = io.SecurityContext(withTrustedRoots: false);
            securityContext.setTrustedCertificatesBytes(certificates);
            return io.HttpClient(context: securityContext);
          };
        }
        // Otherwise: default HttpClient with the platform trust store.
      }
    }

    // 3. Background Transformer
    // On web, isolates are not supported, so we decode JSON synchronously
    // On native platforms, we use isolates for better performance
    dio.transformer = transformer ??
        (BackgroundTransformer()
          ..jsonDecodeCallback = jsonDecodeCallback ??
              (kIsWeb
                  ? (text) => jsonDecode(text) // Synchronous on web
                  : (text) => Isolate.run(
                      () => jsonDecode(text)))); // Background on native

    // 4. Request compression
    final compression = config.compression;
    if (compression != null) {
      dio.interceptors.add(CompressionInterceptor.fromSettings(compression));
    }

    return dio;
  }
}
