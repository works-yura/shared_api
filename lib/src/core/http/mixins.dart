import 'package:shared_api/src/core/http/request.dart';
import 'package:shared_api/src/core/http/response.dart';
import 'package:shared_api/src/core/session/session.dart';
import 'package:shared_api/src/core/http/credentials.dart';

/// Mixin for requests that do not return any data (void).
mixin VoidResponseMixin<S extends HttpState, C extends HttpCredentials>
    on HttpRequest<S, C, void> {
  @override
  void onResponse(HttpResponse response) {}
}

/// Mixin for requests that do not require authentication logic.
mixin NoSessionMixin<C extends HttpCredentials, R>
    on HttpRequest<HttpState, C, R> {
  @override
  HttpState? onSession(R response) => null;
}
