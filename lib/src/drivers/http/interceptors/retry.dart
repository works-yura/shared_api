import 'package:dio/dio.dart';
import 'package:shared_api/src/core/utils/retry_config.dart';

/// An interceptor that automatically retries failed requests.
///
/// Logic:
/// - Retries only idempotent requests (GET, PUT, DELETE, etc.) by default.
/// - Uses exponential backoff.
/// - Respects [RetryConfig].
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final RetryConfig config;

  RetryInterceptor({
    required this.dio,
    this.config = const RetryConfig(),
  });

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final requestOptions = err.requestOptions;

    // Check if we should retry
    if (!_shouldRetry(err, requestOptions)) {
      return handler.next(err);
    }

    var attempt = requestOptions.extra['retry_attempt'] as int? ?? 0;

    if (attempt >= config.maxAttempts) {
      return handler.next(err);
    }

    attempt++;
    requestOptions.extra['retry_attempt'] = attempt;

    final delay = config.getDelayForAttempt(attempt);

    // Check if cancel token was cancelled during delay
    if (requestOptions.cancelToken?.isCancelled == true) {
      return handler.next(err);
    }

    try {
      await Future.delayed(delay);

      // Retry the request
      final response = await dio.fetch(requestOptions);
      return handler.resolve(response);
    } catch (e) {
      // If retry fails, pass the new error (or the old one wrapped)
      if (e is DioException) {
        handler.next(e);
      } else {
        // Wrap generic error into DioException
        handler.next(
          DioException(
            requestOptions: requestOptions,
            error: e,
            type: DioExceptionType.unknown,
          ),
        );
      }
    }
  }

  bool _shouldRetry(DioException err, RequestOptions options) {
    // A request carrying an Idempotency-Key is safe to retry regardless of
    // HTTP method: the server deduplicates by that key, so a network-level
    // retry can't double-apply the side effect. This is what lets mutating
    // writes (POST/PATCH — e.g. saving the birthday) recover from a transient
    // "connection closed" / timeout instead of failing outright. The key is
    // added by IdempotencyInterceptor and stays stable across retries because
    // Dio reuses the same RequestOptions.
    final hasIdempotencyKey = options.headers.containsKey('Idempotency-Key');

    bool isIdempotent = hasIdempotencyKey ||
        options.method == 'GET' ||
        options.method == 'PUT' ||
        options.method == 'DELETE' ||
        options.method == 'HEAD' ||
        options.method == 'OPTIONS';

    // Allow overriding idempotency in extras (takes precedence either way).
    if (options.extra.containsKey('is_idempotent')) {
      isIdempotent = options.extra['is_idempotent'] as bool;
    }

    if (!isIdempotent) return false;

    // Retry on network errors
    if (err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError) {
      return true;
    }

    if (err.type == DioExceptionType.unknown && err.error != null) {
      final errStr = err.error.toString();
      if (errStr.contains('SocketException') || errStr.contains('HttpException')) {
        return true;
      }
    }

    // Retry on specific server errors (e.g., 503 Service Unavailable)
    if (err.type == DioExceptionType.badResponse) {
      final statusCode = err.response?.statusCode;
      if (statusCode == 503 || statusCode == 504) {
        return true;
      }
    }

    return false;
  }
}
