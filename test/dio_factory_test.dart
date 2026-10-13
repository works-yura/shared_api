import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

void main() {
  IOHttpClientAdapter adapterOf(HttpConfig config) =>
      DioFactory(config: config).create().httpClientAdapter
          as IOHttpClientAdapter;

  test('default config keeps platform TLS validation', () {
    final client = adapterOf(const HttpConfig()).createHttpClient;
    expect(client, isNull, reason: 'default HttpClient, system trust store');
  });

  test('allowBadCertificates installs a trust-all client (dev only)', () {
    final create = adapterOf(const HttpConfig(allowBadCertificates: true))
        .createHttpClient;
    // Static tear-offs are canonical, so equality identifies the factory.
    expect(create, DioFactory.insecureHttpClient);
  });

  test('HttpConfig defaults: no pinning, validation on', () {
    const config = HttpConfig();
    expect(config.certificates, isNull);
    expect(config.allowBadCertificates, isFalse);
  });

  test('credentials are secure unless http/ws requested explicitly', () {
    ApiCredentials c(String? scheme) => ApiCredentials(
        host: 'h', scheme: scheme, clientID: '', clientSecret: '');
    expect(c(null).isSecure, isTrue);
    expect(c('https').isSecure, isTrue);
    expect(c('wss').isSecure, isTrue);
    expect(c('http').isSecure, isFalse);
    expect(c('ws').isSecure, isFalse);
  });
}
