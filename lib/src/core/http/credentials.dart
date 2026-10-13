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

  bool get isSecure => scheme == 'https' || scheme == 'wss';
}
