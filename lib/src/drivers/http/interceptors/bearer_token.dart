import 'dart:io' show HttpHeaders;
import 'package:dio/dio.dart';
import 'package:shared_api/shared_api.dart';

class BearerTokenInterceptor extends InterceptorsWrapper {
  final HttpSession<TokenState> session;

  BearerTokenInterceptor({required this.session});

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // The refresh endpoint authenticates with the refresh token in its body,
    // not the access header. Attaching a stale/expired access token here can
    // make the server reject an otherwise-valid refresh.
    if (options.path.contains('/authentication/refresh')) {
      return handler.next(options);
    }

    final state = await session.read();

    if (state is AuthorizedState) {
      options.headers[HttpHeaders.authorizationHeader] =
          'Bearer ${state.access}';
    }

    return handler.next(options);
  }
}
