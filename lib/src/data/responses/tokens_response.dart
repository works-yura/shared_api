import '../shared/types.dart';

/// Example token response returned by sign-in / refresh endpoints.
class TokensResponse extends TokenResponse {
  TokensResponse({
    required super.accessToken,
    required super.refreshToken,
    required super.expiresIn,
  });

  factory TokensResponse.fromJson(JsonObject json) {
    // Handle both camelCase and snake_case
    final expiresIn = json.as<int>('expiresIn', 0) != 0
        ? json.as<int>('expiresIn', 0)
        : json.as<int>('expires_in', 0);

    return TokensResponse(
      accessToken: json.as<String>('accessToken', ''),
      refreshToken: json.as<String>('refreshToken', ''),
      expiresIn: expiresIn,
    );
  }
}
