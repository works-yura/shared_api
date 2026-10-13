import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/drivers/http/interceptors/app_check.dart';

/// Answers 200 and records the App Check header of every call.
class _Adapter implements HttpClientAdapter {
  final seen = <String?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options.headers[AppCheckInterceptor.header] as String?);
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
  }) {
    adapter = _Adapter();
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

  test('a full URL path is matched too', () {
    expect(
      AppCheckInterceptor.isOtpSend(
          'https://api.drunker.app/api/v1.5/authentication/phone/send-otp'),
      isTrue,
    );
    expect(AppCheckInterceptor.isOtpSend('/api/v1/users/me'), isFalse);
  });
}
