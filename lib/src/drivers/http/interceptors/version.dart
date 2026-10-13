import 'package:dio/dio.dart';

/// Interceptor that adds the app version and build number headers
/// ([versionHeader], [buildHeader]; `X-App-Version` and `X-App-Build` by
/// default) to all requests.
class VersionInterceptor extends InterceptorsWrapper {
  final Future<String> Function() getAppVersion;
  final Future<String> Function() getBuildNumber;

  /// Header carrying the app version.
  final String versionHeader;

  /// Header carrying the build number.
  final String buildHeader;

  String? _cachedVersion;
  String? _cachedBuild;

  VersionInterceptor({
    required this.getAppVersion,
    required this.getBuildNumber,
    this.versionHeader = 'X-App-Version',
    this.buildHeader = 'X-App-Build',
  });

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    _cachedVersion ??= await getAppVersion();
    _cachedBuild ??= await getBuildNumber();

    options.headers[versionHeader] = _cachedVersion;
    options.headers[buildHeader] = _cachedBuild;

    return handler.next(options);
  }
}
