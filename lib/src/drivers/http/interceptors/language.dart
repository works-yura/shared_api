import 'dart:io' show HttpHeaders;
import 'package:dio/dio.dart';

/// Interceptor that adds the Accept-Language header to all requests.
class LanguageInterceptor extends InterceptorsWrapper {
  final Future<String> Function() getLanguageCode;

  LanguageInterceptor({required this.getLanguageCode});

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final languageCode = await getLanguageCode();
    options.headers[HttpHeaders.acceptLanguageHeader] = languageCode;

    return handler.next(options);
  }
}
