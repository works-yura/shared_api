import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/drivers/http/interceptors/retry.dart';
import 'package:shared_api/src/drivers/http/interceptors/idempotency.dart';
import 'package:shared_api/src/core/utils/retry_config.dart';

/// A fake HTTP adapter that fails the first [failTimes] calls and then
/// succeeds. Failures are either a thrown network [failType] DioException or,
/// when [failStatus] is set, a real HTTP response with that status code.
/// It records the Idempotency-Key seen on every call so tests can assert the
/// key stays stable across retries.
class _FakeAdapter implements HttpClientAdapter {
  int calls = 0;
  final int failTimes;
  final DioExceptionType failType;
  final int? failStatus;
  final Object? failError;
  final List<String?> seenKeys = [];

  _FakeAdapter({
    this.failTimes = 0,
    this.failType = DioExceptionType.connectionError,
    this.failStatus,
    this.failError,
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    seenKeys.add(options.headers['Idempotency-Key'] as String?);

    if (calls <= failTimes) {
      if (failStatus != null) {
        return ResponseBody.fromString(
          '{"error":true}',
          failStatus!,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      }
      throw DioException(
        requestOptions: options,
        type: failType,
        error: failError,
      );
    }

    return ResponseBody.fromString(
      '{"ok":true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _buildDio(_FakeAdapter adapter, {bool withIdempotency = true}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.httpClientAdapter = adapter;
  if (withIdempotency) {
    dio.interceptors.add(IdempotencyInterceptor());
  }
  dio.interceptors.add(
    RetryInterceptor(
      dio: dio,
      config: const RetryConfig(
        maxAttempts: 3,
        initialDelay: Duration(milliseconds: 1),
      ),
    ),
  );
  return dio;
}

void main() {
  group('RetryInterceptor', () {
    test('retries a PATCH mutation carrying an Idempotency-Key', () async {
      final adapter = _FakeAdapter(failTimes: 1); // fail once, then succeed
      final dio = _buildDio(adapter);

      final res = await dio.patch('/users/me', data: {'birthDate': 'x'});

      expect(res.statusCode, 200);
      expect(adapter.calls, 2, reason: 'one failure + one successful retry');
    });

    test('retries a "Connection closed" HttpException (unknown type + error)',
        () async {
      // Reproduces the real prod failure: dio wraps dart:io HttpException
      // ("Connection closed before full header was received") as
      // DioExceptionType.unknown with `error` set. This must be retried, or a
      // transient keep-alive socket close surfaces as a user-facing error.
      final adapter = _FakeAdapter(
        failTimes: 1,
        failType: DioExceptionType.unknown,
        failError: const HttpException(
          'Connection closed before full header was received',
        ),
      );
      final dio = _buildDio(adapter);

      final res = await dio.patch('/users/me', data: {'birthDate': 'x'});

      expect(res.statusCode, 200);
      expect(adapter.calls, 2, reason: 'connection-closed must be retried');
    });

    test('reuses the SAME Idempotency-Key across retries (server dedupes)',
        () async {
      final adapter = _FakeAdapter(failTimes: 1);
      final dio = _buildDio(adapter);

      await dio.patch('/users/me', data: {'birthDate': 'x'});

      expect(adapter.seenKeys.length, 2);
      expect(adapter.seenKeys[0], isNotNull);
      expect(adapter.seenKeys[0], adapter.seenKeys[1],
          reason: 'retry must reuse the original key, not mint a new one');
    });

    test('does NOT retry a mutation without an Idempotency-Key', () async {
      final adapter = _FakeAdapter(failTimes: 1);
      // No idempotency interceptor → PATCH has no key → unsafe to retry.
      final dio = _buildDio(adapter, withIdempotency: false);

      await expectLater(
        dio.patch('/users/me', data: {'birthDate': 'x'}),
        throwsA(isA<DioException>()),
      );
      expect(adapter.calls, 1, reason: 'no retry for keyless mutation');
    });

    test('retries idempotent GET even without a key', () async {
      final adapter = _FakeAdapter(failTimes: 1);
      final dio = _buildDio(adapter, withIdempotency: false);

      final res = await dio.get('/dictionaries/interests');

      expect(res.statusCode, 200);
      expect(adapter.calls, 2);
    });

    test('stops after maxAttempts and rethrows', () async {
      final adapter = _FakeAdapter(failTimes: 99); // always fails
      final dio = _buildDio(adapter);

      await expectLater(
        dio.patch('/users/me', data: {'x': 1}),
        throwsA(isA<DioException>()),
      );
      // 1 initial attempt + 3 retries (maxAttempts=3).
      expect(adapter.calls, 4);
    });

    test('retries on 503 but NOT on 400', () async {
      final adapter503 = _FakeAdapter(failTimes: 1, failStatus: 503);
      final res = await _buildDio(adapter503).patch('/users/me', data: {});
      expect(res.statusCode, 200);
      expect(adapter503.calls, 2, reason: '503 is retriable');

      final adapter400 = _FakeAdapter(failTimes: 1, failStatus: 400);
      await expectLater(
        _buildDio(adapter400).patch('/users/me', data: {}),
        throwsA(isA<DioException>()),
      );
      expect(adapter400.calls, 1, reason: '400 is a client error, not retried');
    });
  });
}
