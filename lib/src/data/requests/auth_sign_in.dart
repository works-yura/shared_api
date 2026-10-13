import '../shared/types.dart';
import '../responses/tokens_response.dart';

/// Example: sign in and store tokens in session via [TokenSessionMixin].
class AuthSignInRequest extends BaseRequest<TokensResponse>
    with TokenSessionMixin<TokensResponse> {
  final String email;
  final String password;

  AuthSignInRequest({
    required this.email,
    required this.password,
  }) : super('/api/v1/auth/sign-in');

  @override
  HttpOptions onRequest(ApiCredentials credentials) {
    return HttpOptions.post(
      path,
      HttpData.json({
        'email': email,
        'password': password,
      }),
    );
  }

  @override
  TokensResponse onResponse(HttpResponse response) {
    return TokensResponse.fromJson(JsonObject(response.data));
  }
}
