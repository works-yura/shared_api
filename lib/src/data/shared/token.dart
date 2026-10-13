import 'types.dart';

/// Base class for token responses (used by generated classes).
abstract class TokenResponse {
  final String accessToken;
  final String refreshToken;
  final int expiresIn;

  TokenResponse({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresIn,
  });
}

/// Stable base class for Refresh Token requests.
/// Implemented by generated code or manual fallback.
abstract class RefreshTokenRequestBase<R extends TokenResponse>
    extends BaseRequest<R> with TokenSessionMixin<R> {
  final String token;

  RefreshTokenRequestBase({
    required this.token,
    required String path,
  }) : super(path);
}

typedef RefreshRequestFactory = RefreshTokenRequestBase<TokenResponse> Function(
    String token);
