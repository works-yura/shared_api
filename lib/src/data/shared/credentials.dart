import '../../core/core.dart';

class ApiCredentials extends HttpCredentials {
  /// Optional OAuth client id. Never ship a confidential [clientSecret] in a
  /// mobile/web binary: it can be extracted. Use it only for public clients
  /// or server-side code.
  final String? clientID;
  final String? clientSecret;

  const ApiCredentials({
    required String host,
    this.clientID,
    this.clientSecret,
    int? port,
    String? scheme,
    String? path,
  }) : super(
          host: host,
          port: port,
          scheme: scheme,
          path: path,
        );
}
