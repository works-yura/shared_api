import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/drivers/http/interceptors/app_check.dart';

/// The app's one-shot endpoint: both API versions of the OTP send.
bool _isOtpSend(String path) =>
    Uri.parse(path).path.endsWith('/authentication/phone/send-otp');

/// Answers 200 and records the App Check header of every call.
class _Adapter implements HttpClientAdapter {
  final String header;
  _Adapter([this.header = AppCheckInterceptor.header]);

  final seen = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options.headers[header] as String?);
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Adapter adapter;
  late Dio dio;
  var regular = 0;
  var limited = 0;

  Dio build({
    Future<String?> Function()? token,
    Future<String?> Function()? limitedToken,
    bool Function(String path)? isOneShot = _isOtpSend,
    String? headerName,
  }) {
    adapter = headerName == null ? _Adapter() : _Adapter(headerName);
    return Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = adapter
      ..interceptors.add(AppCheckInterceptor(
        getToken: token ??
            () async {
              regular++;
              return 'regular-$regular';
            },
        getLimitedUseToken: limitedToken ??
            () async {
              limited++;
              return 'limited-$limited';
            },
        timeout: const Duration(milliseconds: 50),
        isOneShot: isOneShot ?? (_) => false,
        headerName: headerName ?? AppCheckInterceptor.header,
      ));
  }

  setUp(() {
    regular = 0;
    limited = 0;
    dio = build();
  });

  test('every request carries the regular token', () async {
    await dio.get('/api/v1/users/me');
    await dio.post('/api/v1/swiper/like');
    expect(adapter.seen, ['regular-1', 'regular-2']);
    expect(limited, 0);
  });

  test('send-otp (v1 and v1.5) gets a fresh limited-use token each time',
      () async {
    await dio.post('/api/v1/authentication/phone/send-otp');
    await dio.post('/api/v1.5/authentication/phone/send-otp');
    expect(adapter.seen, ['limited-1', 'limited-2']);
    expect(regular, 0);
  });

  test('other OTP endpoints are not one-shot', () async {
    await dio.post('/api/v1/authentication/phone/verify-otp');
    await dio.get('/api/v1.5/authentication/phone/otp-status');
    expect(adapter.seen, ['regular-1', 'regular-2']);
  });

  test('a re-sent request gets a new token, not the consumed one', () async {
    final options = RequestOptions(
      path: '/api/v1.5/authentication/phone/send-otp',
      method: 'POST',
      baseUrl: 'https://api.test',
    );
    await dio.fetch(options);
    await dio.fetch(options);
    expect(adapter.seen, ['limited-1', 'limited-2']);
  });

  test('no token: the request still goes out, without the header', () async {
    dio = build(token: () async => null);
    await dio.get('/api/v1/users/me');
    expect(adapter.seen, [null]);
  });

  test('a failing provider never fails the request', () async {
    dio = build(token: () async => throw StateError('attestation failed'));
    final res = await dio.get('/api/v1/users/me');
    expect(res.statusCode, 200);
    expect(adapter.seen, [null]);
  });

  test('a hanging provider is cut off by the timeout', () async {
    dio = build(token: () => Completer<String?>().future);
    final res = await dio.get('/api/v1/users/me');
    expect(res.statusCode, 200);
    expect(adapter.seen, [null]);
  });

  test('an empty token is treated as none', () async {
    dio = build(token: () async => '');
    await dio.get('/api/v1/users/me');
    expect(adapter.seen, [null]);
  });

  test('a full URL path is matched too', () async {
    await dio
        .post('https://api.drunker.app/api/v1.5/authentication/phone/send-otp');
    await dio.get('https://api.drunker.app/api/v1/users/me');
    expect(adapter.seen, ['limited-1', 'regular-1']);
  });

  test('by default no request is one-shot', () async {
    dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
      ..httpClientAdapter = adapter
      ..interceptors.add(AppCheckInterceptor(
        getToken: () async => 'regular',
        getLimitedUseToken: () async => 'limited',
      ));
    await dio.post('/api/v1/authentication/phone/send-otp');
    expect(adapter.seen, ['regular']);
  });

  test('custom header name', () async {
    dio = build(headerName: 'X-App-Attest', isOneShot: null);
    await dio.get('/api/v1/users/me');
    expect(adapter.seen, ['regular-1']);
  });
}
