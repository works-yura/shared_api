import '../shared/types.dart';

/// Example: request without response body.
class AuthSignOutRequest extends BaseRequest<void> {
  AuthSignOutRequest() : super('/api/v1/auth/sign-out');

  @override
  HttpOptions onRequest(ApiCredentials credentials) {
    return HttpOptions.post(
      path,
      HttpData.json({}),
    );
  }
}
