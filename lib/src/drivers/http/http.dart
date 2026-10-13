import 'package:shared_api/src/core/utils/try.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_api/src/core/http/request.dart';
import 'package:shared_api/src/core/http/response.dart';
import 'package:shared_api/src/core/utils/observer.dart';
import 'package:shared_api/src/core/exceptions/error_envelope.dart';
import 'package:shared_api/src/core/exceptions/exception.dart';
import 'package:shared_api/src/core/session/session.dart';
import 'package:shared_api/src/core/cache/cache.dart';
import 'package:shared_api/src/core/utils/constants.dart';
import 'package:shared_api/src/drivers/http/interceptors/cache.dart';
import 'package:shared_api/src/data/shared/token.dart';
import './cancel_token.dart';
import './config.dart';
import './factory/dio_factory.dart';
import './error_handler.dart';
import 'package:shared_api/src/core/http/credentials.dart';
import 'package:shared_api/src/core/http/cancel.dart';
import 'package:shared_api/src/core/http/client.dart';
export 'interceptors/interceptors.dart';

/// Client implementation based on the Dio library.
class ApiClient<S extends HttpState, C extends HttpCredentials>
    implements HttpClient<S, C> {
  final Dio dio;
  final HttpConfig config;

  @override
  final HttpSession<S> session;

  @override
  final C credentials;

  final HttpCache cache;
  final List<HttpObserver> observers;

  /// Reads the backend's error body into [HttpResponseException]s.
  final ErrorEnvelopeParser errorEnvelope;

  ApiClient({
    required this.dio,
    required this.config,
    required this.session,
    required this.credentials,
    required this.cache,
    this.observers = const [],
    this.errorEnvelope = const ErrorEnvelopeParser(),
    CacheInterceptor Function(HttpCache cache)? cacheInterceptor,
  }) {
    _installCacheInterceptor(cacheInterceptor);
  }

  /// Wires [cache] into [dio] via [CacheInterceptor], unless one is already
  /// installed. It goes first so a cache hit short-circuits auth, retry and
  /// network interceptors (and stale data can be served offline).
  ///
  /// [build] customises it (e.g. `varyHeaders`, `defaultTtl`,
  /// `cacheKeyBuilder`); by default `CacheInterceptor(cache: cache)`.
  void _installCacheInterceptor(
      CacheInterceptor Function(HttpCache cache)? build) {
    for (final interceptor in dio.interceptors) {
      if (interceptor is CacheInterceptor) {
        interceptor.dio ??= dio;
        return;
      }
    }
    final interceptor = build?.call(cache) ?? CacheInterceptor(cache: cache);
    dio.interceptors.insert(0, interceptor..dio ??= dio);
  }

  /// Configure all requests
  void configure() {
    dio.options.connectTimeout = config.connectTimeout;
    dio.options.receiveTimeout = config.receiveTimeout;
    dio.options.sendTimeout = config.sendTimeout;

    if (config.headers != null) {
      dio.options.headers.addAll(config.headers!);
    }

    dio.options.contentType = Headers.jsonContentType;
    dio.options.responseType = ResponseType.json;
  }

  @override
  Future<Try<HttpException, R>> execute<R>(HttpRequest<S, C, R> request,
      {HttpCancelToken? cancelToken}) async {
    final options = request.onRequest(credentials);
    final stopwatch = Stopwatch()..start();

    // Notify observers about request
    for (var o in observers) {
      o.onRequest(options.path, options.method.value, options.queries);
    }

    // Resolve Target URI via Service Discovery
    final targetUri = _resolveUri(request.service, options.path);

    final dioToken =
        (cancelToken is DioCancelToken) ? cancelToken.underlying : null;

    try {
      final response = await dio.request<dynamic>(
        targetUri.toString(),
        data: options.data?.when(
          json: (data) => data,
          multipart: (data) => FormData.fromMap(data),
          other: (data) => data,
        ),
        queryParameters: options.queries,
        cancelToken: dioToken,
        options: Options(
          method: options.method.value,
          headers: options.headers,
          extra: {
            ...?options.extra,
            HttpConstants.cachePolicyKey: options.cachePolicy,
            if (request is RefreshTokenRequestBase)
              HttpConstants.refreshRequestKey: true,
          },
        ),
      );

      stopwatch.stop();
      for (var o in observers) {
        o.onResponse(
            options.path, stopwatch.elapsed, response.statusCode ?? 200);
      }

      final httpResponse = _mapDioResponse(response);
      final result = request.onResponse(httpResponse);

      debugPrint(
          '[ApiClient] Result type: ${request.onResponse.runtimeType.toString().split('=>').last.trim()}');
      debugPrint('[ApiClient] Result type: ${result.runtimeType}');
      debugPrint('[ApiClient] Mapping result to session...');

      final newState = request.onSession(result);
      if (newState != null) {
        debugPrint(
            '[ApiClient] New session state detected: ${newState.runtimeType}. Updating session...');
        await session.update(newState);
        debugPrint('[ApiClient] Session updated successfuly.');
      } else {
        debugPrint(
            '[ApiClient] No new session state for this request (onSession returned null).');
      }

      return Try.success(result);
    } on DioException catch (e) {
      final exception = DioErrorHandler.handle(e, envelope: errorEnvelope);
      for (var o in observers) {
        o.onError(exception);
      }
      return Try.failed(exception);
    } catch (e) {
      final exception = HttpException.unknown(message: e.toString());
      for (var o in observers) {
        o.onError(exception);
      }
      return Try.failed(exception);
    }
  }

  @override
  Future<Try<HttpException, void>> uploadFile(String url, String filePath,
      {Map<String, String>? headers,
      HttpCancelToken? cancelToken,
      void Function(int sent, int total)? onProgress}) async {
    final dioToken =
        (cancelToken is DioCancelToken) ? cancelToken.underlying : null;

    try {
      final file = await MultipartFile.fromFile(filePath);

      // ARCHITECTURAL FIX: Use a fresh, clean Dio instance for external uploads.
      // This ensures that global interceptors (like those adding Authorization headers)
      // do not interfere with presigned S3/MinIO URLs.
      final cleanDio = Dio();

      // Presigned URLs point at storage hosts, not the API: never inherit API
      // certificate pinning. Only the explicit dev bypass is mirrored.
      final target = cleanDio.httpClientAdapter;
      if (!kIsWeb &&
          config.allowBadCertificates &&
          target is IOHttpClientAdapter) {
        target.createHttpClient = DioFactory.insecureHttpClient;
      }

      await cleanDio.put<void>(
        url,
        data: file.finalize(),
        cancelToken: dioToken,
        onSendProgress: onProgress, // PASS PROGRESS HERE
        options: Options(
          headers: {
            Headers.contentTypeHeader: 'application/octet-stream',
            ...?headers,
            Headers.contentLengthHeader: file.length,
          },
        ),
      );

      return Try.success(null);
    } on DioException catch (e) {
      final exception = DioErrorHandler.handle(e, envelope: errorEnvelope);
      return Try.failed(exception);
    } catch (e) {
      return Try.failed(HttpException.unknown(message: e.toString()));
    }
  }

  HttpResponse _mapDioResponse(Response response) {
    return HttpResponse(
      data: response.data,
      status: response.statusCode ?? 200,
      headers: response.headers.map,
    );
  }

  /// Resolves the full URI, considering microservice discovery.
  Uri _resolveUri(String? serviceName, String requestPath) {
    // If service is specified and present in config -> use its host
    final serviceBase =
        (serviceName != null) ? config.services[serviceName] : null;

    if (serviceBase != null) {
      // Parse service base URL (e.g. https://api.payments.example.com)
      final baseUri = Uri.parse(serviceBase);
      return baseUri.replace(
        path: _normalizePath(baseUri.path, requestPath),
      );
    }

    // Default fallback: use standard credentials
    return Uri(
      scheme: credentials.isSecure ? 'https' : 'http',
      host: credentials.host,
      port: credentials.port,
      path: _normalizePath(credentials.path ?? '', requestPath),
    );
  }

  String _normalizePath(String base, String request) {
    final cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanRequest = request.startsWith('/') ? request : '/$request';
    return '$cleanBase$cleanRequest';
  }
}
