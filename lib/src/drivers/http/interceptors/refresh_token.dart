import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'dart:io' show HttpHeaders, HttpStatus;
import 'package:synchronized/synchronized.dart';
import 'package:shared_api/shared_api.dart';
import 'package:shared_api/src/drivers/http/http.dart';
import 'package:shared_api/src/data/shared/types.dart';
import '../../session/session.dart';

class InvalidRefreshTokenException extends DioException {
  InvalidRefreshTokenException({required super.requestOptions});
}

class RefreshTokenInterceptor extends InterceptorsWrapper {
  final Dio dio;
  final HttpSession<TokenState> session;
  final ApiClient client;
  final RefreshRequestFactory refreshRequestFactory;
  final Lock _lock = Lock();

  /// Marks a request that is a retry/refresh issued by this interceptor, so a
  /// repeated 401 on it is passed through instead of re-entering the
  /// non-reentrant [_lock] (which would DEADLOCK the whole client).
  static const _retryFlag = '__refreshInterceptorRetry';

  RefreshTokenInterceptor({
    required this.dio,
    required this.session,
    required this.client,
    required this.refreshRequestFactory,
  });

  @override
  Future<void> onError(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    // 1. 401/403 check for SECURED requests only
    if (!(_isUnauthorizedError(error) &&
        _isRequestSecured(error.requestOptions))) {
      return handler.next(error);
    }

    // A 401 on our own retry, or on the refresh call itself, must NOT re-enter
    // the lock — that would deadlock (the lock is held by the flow awaiting
    // this very request). Pass it through so the outer flow reads the failure.
    if (error.requestOptions.extra[_retryFlag] == true ||
        _isRefreshRequest(error.requestOptions)) {
      return handler.next(error);
    }

    debugPrint(
        '[RefreshTokenInterceptor] 401/403 detected for ${error.requestOptions.path}. Attempting synchronized refresh...');

    try {
      final response = await _lock.synchronized<Response<dynamic>>(() async {
        final currentState = await session.read();

        if (currentState is AuthorizedState) {
          try {
            debugPrint(
                '[RefreshTokenInterceptor] Already authorized. Retrying with existing token...');
            final response = await retry(error.requestOptions);
            return response;
          } on DioException catch (retryError) {
            // Check for explicit expiry during retry too
            if (_isSessionExpiredMessage(retryError)) {
              await _logOut();
              rethrow;
            }

            if (!_isUnauthorizedError(retryError)) {
              rethrow;
            }
            debugPrint(
                '[RefreshTokenInterceptor] Retry with existing token failed with 401. Proceeding to refresh.');
          }
        }

        if (currentState is! AuthorizedState) {
          debugPrint(
              '[RefreshTokenInterceptor] No authorized state found. Stopping.');
          throw InvalidRefreshTokenException(
              requestOptions: error.requestOptions);
        }

        try {
          debugPrint('[RefreshTokenInterceptor] Requesting new tokens...');
          final refreshRequest = refreshRequestFactory(currentState.refresh);
          final result = await client.execute<TokenResponse>(refreshRequest);

          if (result.isFailed()) {
            final failure =
                result.fold((f) => f, (s) => throw StateError('Unreachable'));
            debugPrint('[RefreshTokenInterceptor] Refresh failed: $failure');

            // If refresh fails with 401, it means the session is completely gone.
            if (failure is HttpResponseException) {
              if (failure.status == 401 || failure.status == 403) {
                await _logOut();
              }
            }
            throw InvalidRefreshTokenException(
                requestOptions: error.requestOptions);
          }

          debugPrint(
              '[RefreshTokenInterceptor] Refresh successful. Retrying original request.');
          return await retry(error.requestOptions);
        } catch (e) {
          debugPrint('[RefreshTokenInterceptor] Error during refresh: $e');

          if (e is DioException && _isSessionExpiredMessage(e)) {
            await _logOut();
          } else if (e is! InvalidRefreshTokenException) {
            await _logOut();
          }
          rethrow;
        }
      });

      handler.resolve(response);
    } on DioException catch (e) {
      handler.next(e);
    } catch (e) {
      handler.next(
        DioException(
          requestOptions: error.requestOptions,
          error: e,
        ),
      );
    }
  }

  // Only 401 means "token invalid/expired → try to refresh". A 403 is a
  // business-authorization failure (e.g. "only the owner can do X"): refreshing
  // won't help, and treating it as an auth error made a legitimate 403 flow
  // through the refresh path and ultimately log the user out. Pass 403 through
  // as a normal error so the caller can surface it.
  bool _isUnauthorizedError(DioException error) =>
      error.response?.statusCode == HttpStatus.unauthorized;

  bool _isSessionExpiredMessage(DioException error) {
    final data = error.response?.data;
    if (data is Map) {
      return data['message'] == 'authentication.session_expired' ||
          data['error'] == 'UNAUTHORIZED' &&
              data['statusCode'] == 401 &&
              data['message'] == 'authentication.session_expired';
    }
    return false;
  }

  Future<void> _logOut() async {
    await session.update(
        TokenState.unauthorized(reason: UnauthorizedReason.sessionExpired));
  }

  bool _isRequestSecured(RequestOptions options) =>
      options.headers.containsKey(HttpHeaders.authorizationHeader);

  bool _isRefreshRequest(RequestOptions options) =>
      options.path.contains('/authentication/refresh');

  Future<Response<dynamic>> retry(RequestOptions options) async {
    final state = await session.read();
    if (state is AuthorizedState) {
      options.headers[HttpHeaders.authorizationHeader] =
          'Bearer ${state.access}';
    }

    final request = Options(
      method: options.method,
      headers: options.headers,
      // Tag the retry so a repeated 401 is passed through (no lock re-entry),
      // while STILL flowing through all other interceptors (country, language,
      // version, …) on the main dio so no headers are lost.
      extra: {...options.extra, _retryFlag: true},
    ).compose(
      dio.options,
      options.path,
      data: options.data,
      queryParameters: options.queryParameters,
      cancelToken: options.cancelToken,
      onReceiveProgress: options.onReceiveProgress,
      onSendProgress: options.onSendProgress,
    );
    return dio.fetch<dynamic>(request);
  }
}
