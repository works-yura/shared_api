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

/// Decides something about a failed request (e.g. "is this a 401?").
typedef DioErrorPredicate = bool Function(DioException error);

/// Decides whether a failed refresh call means the refresh token itself was
/// rejected, i.e. the session is gone and the user must sign in again.
typedef RefreshRejectedPredicate = bool Function(HttpException failure);

/// Default [RefreshTokenInterceptor.isUnauthorized]: only 401.
///
/// A 403 is a business-authorization failure (e.g. "only the owner can do
/// X"): refreshing won't help, and treating it as an auth error made a
/// legitimate 403 flow through the refresh path and ultimately log the user
/// out. It is passed through as a normal error so the caller can surface it.
bool defaultIsUnauthorized(DioException error) =>
    error.response?.statusCode == HttpStatus.unauthorized;

/// Default [RefreshTokenInterceptor.isSessionExpired]: the body says
/// `message: 'authentication.session_expired'`.
bool defaultIsSessionExpired(DioException error) {
  final data = error.response?.data;
  if (data is Map) {
    return data['message'] == 'authentication.session_expired' ||
        data['error'] == 'UNAUTHORIZED' &&
            data['statusCode'] == 401 &&
            data['message'] == 'authentication.session_expired';
  }
  return false;
}

/// Default refresh-rejection check shared by [RefreshTokenInterceptor] and
/// [ApiCoordinator]: the refresh endpoint answered 401 or 403.
bool defaultIsRefreshRejected(HttpException failure) =>
    failure is HttpResponseException &&
    (failure.status == 401 || failure.status == 403);

class RefreshTokenInterceptor extends InterceptorsWrapper {
  final Dio dio;
  final HttpSession<TokenState> session;
  final ApiClient client;
  final RefreshRequestFactory refreshRequestFactory;

  /// Whether an error means "access token invalid/expired -> try to refresh".
  final DioErrorPredicate isUnauthorized;

  /// Whether an error means the session is definitively over (log out, no
  /// refresh attempt).
  final DioErrorPredicate isSessionExpired;

  /// Whether a failed refresh call means the session is gone (log out).
  final RefreshRejectedPredicate isRefreshRejected;

  /// Header the access token is sent in.
  final String authHeaderName;

  /// Builds the [authHeaderName] value for an access token.
  final AuthHeaderBuilder authHeaderValue;

  /// Whether a request was sent with credentials, i.e. a 401 on it is worth a
  /// refresh. Defaults to "carries [authHeaderName]".
  final bool Function(RequestOptions options) isSecured;

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
    this.isUnauthorized = defaultIsUnauthorized,
    this.isSessionExpired = defaultIsSessionExpired,
    this.isRefreshRejected = defaultIsRefreshRejected,
    this.authHeaderName = HttpHeaders.authorizationHeader,
    this.authHeaderValue = bearerAuthHeader,
    bool Function(RequestOptions options)? isSecured,
  }) : isSecured = isSecured ??
            ((options) => options.headers.containsKey(authHeaderName));

  @override
  Future<void> onError(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    // 1. 401/403 check for SECURED requests only
    if (!(isUnauthorized(error) && isSecured(error.requestOptions))) {
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
            if (isSessionExpired(retryError)) {
              await _logOut();
              rethrow;
            }

            if (!isUnauthorized(retryError)) {
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

            // A rejected refresh token means the session is completely gone.
            if (isRefreshRejected(failure)) {
              await _logOut();
            }
            throw InvalidRefreshTokenException(
                requestOptions: error.requestOptions);
          }

          debugPrint(
              '[RefreshTokenInterceptor] Refresh successful. Retrying original request.');
          return await retry(error.requestOptions);
        } catch (e) {
          debugPrint('[RefreshTokenInterceptor] Error during refresh: $e');

          if (e is DioException && isSessionExpired(e)) {
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

  Future<void> _logOut() async {
    await session.update(
        TokenState.unauthorized(reason: UnauthorizedReason.sessionExpired));
  }

  bool _isRefreshRequest(RequestOptions options) =>
      options.extra[HttpConstants.refreshRequestKey] == true;

  Future<Response<dynamic>> retry(RequestOptions options) async {
    final state = await session.read();
    if (state is AuthorizedState) {
      options.headers[authHeaderName] = authHeaderValue(state.access);
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
