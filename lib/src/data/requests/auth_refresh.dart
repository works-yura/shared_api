import '../shared/types.dart';
import '../responses/tokens_response.dart';

/// Example: refresh token request. Pass a factory of it to
/// [ApiCoordinator.refreshRequestFactory].
class AuthRefreshRequest extends RefreshTokenRequestBase<TokensResponse> {
  AuthRefreshRequest({
    required String refreshToken,
  }) : super(token: refreshToken, path: '/api/v1/auth/refresh');

  @override
  HttpOptions onRequest(ApiCredentials credentials) {
    return HttpOptions.post(
      path,
      HttpData.json({'refreshToken': token}),
    );
  }

  @override
  TokensResponse onResponse(HttpResponse response) {
    return TokensResponse.fromJson(JsonObject(response.data));
  }
}
