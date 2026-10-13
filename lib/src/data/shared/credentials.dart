import '../../core/core.dart';

class ApiCredentials extends HttpCredentials {
  final String clientID;
  final String clientSecret;

  const ApiCredentials({
    required String host,
    required this.clientID,
    required this.clientSecret,
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
