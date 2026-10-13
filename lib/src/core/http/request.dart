import 'package:shared_api/src/core/session/session.dart';
import 'package:shared_api/src/core/http/credentials.dart';
import 'package:shared_api/src/core/http/options.dart';
import 'package:shared_api/src/core/http/response.dart';

abstract class HttpRequest<State extends HttpState,
    Credentials extends HttpCredentials, Response> {
  HttpOptions onRequest(Credentials credentials);

  Response onResponse(HttpResponse response) {
    final data = response.data;
    if (data is Response) return data;
    throw StateError(
        'API response type mismatch: expected $Response, got ${data.runtimeType}');
  }

  State? onSession(Response response) => null;

  Exception onException(Exception exception) => exception;

  /// The microservice name for service discovery.
  String? get service => null;

  bool get isHeavy => false;
}
