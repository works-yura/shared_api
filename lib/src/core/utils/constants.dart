class HttpConstants {
  static const String cachePolicyKey = 'cache_Policy';

  /// Marks a token refresh request (set by ApiClient for
  /// RefreshTokenRequestBase). Auth interceptors skip the access header and
  /// never try to refresh-on-401 for it, whatever its path is.
  static const String refreshRequestKey = 'shared_api.refresh_request';
}
