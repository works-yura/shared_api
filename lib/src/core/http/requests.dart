import 'package:shared_api/src/core/session/session.dart';
import 'package:shared_api/src/core/http/credentials.dart';
import 'package:shared_api/src/core/utils/json.dart';
import 'package:shared_api/src/core/http/request.dart';
import 'package:shared_api/src/core/http/response.dart';

/// Universal base class for requests with a [path].
abstract class GenericBaseRequest<S extends HttpState,
    C extends HttpCredentials, R> extends HttpRequest<S, C, R> {
  final String path;

  GenericBaseRequest(this.path);
}

/// A request that processes JSON responses.
abstract class GenericJsonRequest<S extends HttpState,
    C extends HttpCredentials, R> extends GenericBaseRequest<S, C, R> {
  GenericJsonRequest(super.path);

  @override
  R onResponse(HttpResponse response) {
    return onJsonResponse(JsonObject(response.data), response);
  }

  /// Called when a JSON response is received.
  R onJsonResponse(JsonObject json, HttpResponse response);
}
