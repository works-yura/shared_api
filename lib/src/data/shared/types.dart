import 'package:flutter/foundation.dart';
import 'package:shared_api/src/data/shared/token.dart';
import 'package:shared_api/src/drivers/session/state.dart';
import 'package:shared_api/src/data/shared/credentials.dart';
import 'package:shared_api/src/core/http/request.dart';
import 'package:shared_api/src/core/http/requests.dart';

export 'package:shared_api/src/drivers/session/state.dart'
    show TokenState, UnauthorizedReason;
export 'package:shared_api/src/data/shared/credentials.dart'
    show ApiCredentials;
export 'package:shared_api/src/core/http/request.dart' show HttpRequest;
export 'package:shared_api/src/core/http/requests.dart'
    show GenericBaseRequest, GenericJsonArrayRequest, GenericJsonRequest;
export 'package:shared_api/src/core/http/options.dart' show HttpOptions;
export 'package:shared_api/src/core/http/response.dart' show HttpResponse;
export 'package:shared_api/src/core/http/data.dart' show HttpData;
export 'package:shared_api/src/core/utils/json.dart' show JsonObject;
export 'package:shared_api/src/data/shared/token.dart'
    show TokenResponse, RefreshTokenRequestBase, RefreshRequestFactory;

typedef ClientRequest<T> = HttpRequest<TokenState, ApiCredentials, T>;

/// Base class for all API requests specialized for the current client.
abstract class BaseRequest<R>
    extends GenericBaseRequest<TokenState, ApiCredentials, R> {
  BaseRequest(super.path);

  @override
  TokenState? onSession(R response) {
    debugPrint('[BaseRequest] onSession called for ${this.runtimeType}');
    return null;
  }
}

/// A request that processes JSON responses specialized for the current client.
abstract class JsonRequest<R>
    extends GenericJsonRequest<TokenState, ApiCredentials, R> {
  JsonRequest(super.path);
}

/// A request whose response is a top-level JSON array. Each element is
/// mapped via [mapItem] to a single `T`; the request returns `List<T>`.
abstract class JsonArrayRequest<T>
    extends GenericJsonArrayRequest<TokenState, ApiCredentials, T> {
  JsonArrayRequest(super.path);
}

/// Mixin for requests that return authentication tokens.
///
/// Automatically handles the [onSession] mapping to [TokenState].
/// Requires the response type [R] to extend [TokenResponse].
mixin TokenSessionMixin<R extends TokenResponse>
    on HttpRequest<TokenState, ApiCredentials, R> {
  @override
  TokenState onSession(R response) {
    debugPrint('[TokenSessionMixin] Mapping response to session state...');
    return TokenState.authorized(
      access: response.accessToken,
      refresh: response.refreshToken,
      expiresIn: response.expiresIn,
      createdAt: DateTime.now(), // Store creation time
    );
  }
}
