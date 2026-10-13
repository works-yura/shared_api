import 'package:dio/dio.dart';

/// Interceptor that adds the X-App-Version and X-App-Build headers to all requests.
class VersionInterceptor extends InterceptorsWrapper {
  final Future<String> Function() getAppVersion;
  final Future<String> Function() getBuildNumber;

  String? _cachedVersion;
  String? _cachedBuild;

  VersionInterceptor({
    required this.getAppVersion,
    required this.getBuildNumber,
  });

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    _cachedVersion ??= await getAppVersion();
    _cachedBuild ??= await getBuildNumber();

    options.headers['X-App-Version'] = _cachedVersion;
    options.headers['X-App-Build'] = _cachedBuild;

    return handler.next(options);
  }
}
