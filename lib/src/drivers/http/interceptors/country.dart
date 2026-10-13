import 'package:dio/dio.dart';

/// Interceptor that adds the X-Country-Code header to all requests.
class CountryInterceptor extends InterceptorsWrapper {
  final Future<String?> Function() getCountryCode;

  CountryInterceptor({required this.getCountryCode});

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final countryCode = await getCountryCode();
    if (countryCode != null) {
      options.headers['x-country-code'] = countryCode;
    }

    return handler.next(options);
  }
}
