import 'dart:io' show HttpHeaders;
import 'package:dio/dio.dart';
import 'package:shared_api/shared_api.dart';

/// Builds the value of the auth header for an access token.
typedef AuthHeaderBuilder = String Function(String accessToken);

/// Default [AuthHeaderBuilder]: `Bearer <token>`.
String bearerAuthHeader(String accessToken) => 'Bearer $accessToken';

class BearerTokenInterceptor extends InterceptorsWrapper {
  final HttpSession<TokenState> session;

  /// Header the access token is sent in.
  final String headerName;

  /// Builds the [headerName] value, e.g. `(t) => 'Token $t'` or `(t) => t`.
  final AuthHeaderBuilder headerValue;

  BearerTokenInterceptor({
    required this.session,
    this.headerName = HttpHeaders.authorizationHeader,
    this.headerValue = bearerAuthHeader,
  });

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // The refresh endpoint authenticates with the refresh token in its body,
    // not the access header. Attaching a stale/expired access token here can
    // make the server reject an otherwise-valid refresh.
    if (options.extra[HttpConstants.refreshRequestKey] == true) {
      return handler.next(options);
    }

    final state = await session.read();

    if (state is AuthorizedState) {
      options.headers[headerName] = headerValue(state.access);
    }

    return handler.next(options);
  }
}
