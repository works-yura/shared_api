import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_api/src/core/utils/retry_config.dart';

/// An interceptor that automatically retries failed requests.
///
/// Logic:
/// - Retries only when [retryIf] approves the error. The default,
///   [defaultRetryIf], retries idempotent requests (GET, PUT, DELETE, HEAD,
///   OPTIONS, or any request carrying an `Idempotency-Key`) on network errors
///   and `503` / `504`.
/// - Uses exponential backoff, or the server's `Retry-After` header when the
///   error response carries one (capped by [RetryConfig.maxDelay]).
/// - Respects [RetryConfig].
class RetryInterceptor extends Interceptor {
  /// `RequestOptions.extra` key holding the number of retries done so far.
  static const attemptKey = 'retry_attempt';

  /// `RequestOptions.extra` key that forces a request to be treated as
  /// idempotent (`true`) or not (`false`), overriding the method/header check.
  static const idempotentKey = 'is_idempotent';

  final Dio dio;
  final RetryConfig config;

  /// Decides whether a failed request is retried. Defaults to
  /// [defaultRetryIf]; compose it with [isIdempotentRequest] and
  /// [isTransientError] to extend rather than replace the default.
  final bool Function(DioException err) retryIf;

  RetryInterceptor({
    required this.dio,
    this.config = const RetryConfig(),
    bool Function(DioException err)? retryIf,
  }) : retryIf = retryIf ?? defaultRetryIf;

  /// Default retry predicate: an idempotent request that failed transiently.
  static bool defaultRetryIf(DioException err) =>
      isIdempotentRequest(err.requestOptions) && isTransientError(err);

  /// Whether [options] is safe to send twice.
  ///
  /// A request carrying an [idempotencyHeader] is safe to retry regardless of
  /// HTTP method: the server deduplicates by that key, so a network-level
  /// retry can't double-apply the side effect. The key stays stable across
  /// retries because Dio reuses the same [RequestOptions].
  ///
  /// `extra[idempotentKey]` takes precedence either way.
  static bool isIdempotentRequest(
    RequestOptions options, {
    String idempotencyHeader = 'Idempotency-Key',
  }) {
    final override = options.extra[idempotentKey];
    if (override is bool) return override;

    return options.headers.containsKey(idempotencyHeader) ||
        options.method == 'GET' ||
        options.method == 'PUT' ||
        options.method == 'DELETE' ||
        options.method == 'HEAD' ||
        options.method == 'OPTIONS';
  }

  /// Whether [err] is a transient failure worth retrying: timeouts,
  /// connection errors, socket / HTTP-level I/O errors and `503` / `504`.
  static bool isTransientError(DioException err) {
    if (err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError) {
      return true;
    }

    if (err.type == DioExceptionType.unknown && err.error != null) {
      final errStr = err.error.toString();
      if (errStr.contains('SocketException') ||
          errStr.contains('HttpException')) {
        return true;
      }
    }

    if (err.type == DioExceptionType.badResponse) {
      final statusCode = err.response?.statusCode;
      if (statusCode == 503 || statusCode == 504) {
        return true;
      }
    }

    return false;
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final requestOptions = err.requestOptions;

    // Check if we should retry
    if (!retryIf(err)) {
      return handler.next(err);
    }

    var attempt = requestOptions.extra[attemptKey] as int? ?? 0;

    if (attempt >= config.maxAttempts) {
      return handler.next(err);
    }

    attempt++;
    requestOptions.extra[attemptKey] = attempt;

    final delay =
        _retryAfter(err.response) ?? config.getDelayForAttempt(attempt);

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

  /// Parses `Retry-After` (delta-seconds or HTTP-date) into a delay clamped to
  /// `[0, config.maxDelay]`. Returns null when absent or malformed, so the
  /// regular backoff applies.
  Duration? _retryAfter(Response? response) {
    final value = response?.headers.value('retry-after')?.trim();
    if (value == null || value.isEmpty) return null;

    Duration delay;
    final seconds = int.tryParse(value);
    if (seconds != null) {
      delay = Duration(seconds: seconds);
    } else {
      try {
        delay = HttpDate.parse(value).difference(DateTime.now());
      } catch (_) {
        return null;
      }
    }

    if (delay.isNegative) return Duration.zero;
    return delay > config.maxDelay ? config.maxDelay : delay;
  }
}
