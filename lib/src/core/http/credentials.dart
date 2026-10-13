abstract class HttpCredentials {
  final String host;
  final int? port;
  final String? scheme;
  final String? path;

  const HttpCredentials({
    required this.host,
    this.port,
    this.scheme,
    this.path,
  });

  /// Secure unless plain `http` / `ws` is requested explicitly: a missing
  /// [scheme] must never silently downgrade to cleartext.
  bool get isSecure => scheme != 'http' && scheme != 'ws';
}
