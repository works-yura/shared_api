import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:talker_dio_logger/talker_dio_logger.dart';

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

  Dio create() {
    final dio = Dio();

    // 1. Base Options
    dio.options.connectTimeout = config.connectTimeout;
    dio.options.sendTimeout = config.sendTimeout;
    dio.options.receiveTimeout = config.receiveTimeout;

    if (config.headers != null) {
      dio.options.headers.addAll(config.headers!);
    }

    // 2. SSL & Platform Config
    if (!kIsWeb) {
      if (config.certificates != null) {
        (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
          final securityContext = io.SecurityContext(withTrustedRoots: false);
          securityContext.setTrustedCertificatesBytes(config.certificates!);
          return io.HttpClient(context: securityContext);
        };
      } else {
        // Unsafe / Dev mode
        (dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
          final client = io.HttpClient();
          client.badCertificateCallback = (cert, host, port) => true;
          return client;
        };
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

    return dio;
  }
}
