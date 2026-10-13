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
  final Map<String, String> failHeaders;
  final List<String?> seenKeys = [];

  _FakeAdapter({
    this.failTimes = 0,
    this.failType = DioExceptionType.connectionError,
    this.failStatus,
    this.failError,
    this.failHeaders = const {},
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
            for (final e in failHeaders.entries) e.key: [e.value],
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

Dio _buildDio(
  _FakeAdapter adapter, {
  bool withIdempotency = true,
  RetryConfig config = const RetryConfig(
    maxAttempts: 3,
    initialDelay: Duration(milliseconds: 1),
  ),
  bool Function(DioException err)? retryIf,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.httpClientAdapter = adapter;
  if (withIdempotency) {
    dio.interceptors.add(IdempotencyInterceptor());
  }
  dio.interceptors.add(
    RetryInterceptor(
      dio: dio,
      config: config,
      retryIf: retryIf,
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

    test('records the attempt count under the public extra key', () async {
      final adapter = _FakeAdapter(failTimes: 2);
      final dio = _buildDio(adapter);

      final res = await dio.get('/x');

      expect(res.requestOptions.extra[RetryInterceptor.attemptKey], 2);
      expect(RetryInterceptor.attemptKey, 'retry_attempt');
      expect(RetryInterceptor.idempotentKey, 'is_idempotent');
    });

    test('idempotentKey extra overrides the method check', () async {
      final noRetry = _FakeAdapter(failTimes: 1);
      await expectLater(
        _buildDio(noRetry, withIdempotency: false).get(
          '/x',
          options: Options(extra: {RetryInterceptor.idempotentKey: false}),
        ),
        throwsA(isA<DioException>()),
      );
      expect(noRetry.calls, 1);

      final retry = _FakeAdapter(failTimes: 1);
      await _buildDio(retry, withIdempotency: false).post(
        '/x',
        options: Options(extra: {RetryInterceptor.idempotentKey: true}),
      );
      expect(retry.calls, 2);
    });

    group('retryIf', () {
      test('custom predicate can retry what the default would not (429)',
          () async {
        final adapter = _FakeAdapter(failTimes: 1, failStatus: 429);
        final dio = _buildDio(
          adapter,
          retryIf: (e) =>
              RetryInterceptor.defaultRetryIf(e) ||
              (RetryInterceptor.isIdempotentRequest(e.requestOptions) &&
                  e.response?.statusCode == 429),
        );

        final res = await dio.get('/x');

        expect(res.statusCode, 200);
        expect(adapter.calls, 2);
      });

      test('custom idempotency header makes a mutation retryable', () async {
        final adapter = _FakeAdapter(failTimes: 1);
        final dio = Dio(BaseOptions(baseUrl: 'http://test.local'))
          ..httpClientAdapter = adapter;
        dio.interceptors
          ..add(IdempotencyInterceptor(headerName: 'X-Request-Id'))
          ..add(RetryInterceptor(
            dio: dio,
            config: const RetryConfig(initialDelay: Duration(milliseconds: 1)),
            retryIf: (e) =>
                RetryInterceptor.isIdempotentRequest(e.requestOptions,
                    idempotencyHeader: 'X-Request-Id') &&
                RetryInterceptor.isTransientError(e),
          ));

        final res = await dio.post('/x');

        expect(res.statusCode, 200);
        expect(adapter.calls, 2);
      });

      test('custom predicate can veto retries the default would allow',
          () async {
        final adapter = _FakeAdapter(failTimes: 1);
        final dio = _buildDio(adapter, retryIf: (_) => false);

        await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
        expect(adapter.calls, 1);
      });

      test('default predicate: 429 and 500 are not retried', () async {
        for (final status in [429, 500]) {
          final adapter = _FakeAdapter(failTimes: 1, failStatus: status);
          await expectLater(
            _buildDio(adapter).get('/x'),
            throwsA(isA<DioException>()),
          );
          expect(adapter.calls, 1, reason: '$status');
        }
      });

      test('default predicate: 504 and SocketException are retried', () async {
        final a504 = _FakeAdapter(failTimes: 1, failStatus: 504);
        await _buildDio(a504).get('/x');
        expect(a504.calls, 2);

        final socket = _FakeAdapter(
          failTimes: 1,
          failType: DioExceptionType.unknown,
          failError: const SocketException('reset'),
        );
        await _buildDio(socket).get('/x');
        expect(socket.calls, 2);
      });
    });

    group('Retry-After', () {
      // A huge backoff that would time the test out if it were used.
      const slowBackoff = RetryConfig(
        maxAttempts: 1,
        initialDelay: Duration(minutes: 1),
        maxDelay: Duration(minutes: 1),
      );

      test('delta-seconds replaces the exponential backoff', () async {
        final adapter = _FakeAdapter(
          failTimes: 1,
          failStatus: 503,
          failHeaders: {'retry-after': '0'},
        );
        final sw = Stopwatch()..start();

        final res = await _buildDio(adapter, config: slowBackoff).get('/x');

        expect(res.statusCode, 200);
        expect(adapter.calls, 2);
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      });

      test('HTTP-date in the past retries immediately', () async {
        final adapter = _FakeAdapter(
          failTimes: 1,
          failStatus: 503,
          failHeaders: {
            'retry-after': HttpDate.format(
                DateTime.now().subtract(const Duration(hours: 1))),
          },
        );
        final sw = Stopwatch()..start();

        await _buildDio(adapter, config: slowBackoff).get('/x');

        expect(adapter.calls, 2);
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      });

      test('is capped by RetryConfig.maxDelay', () async {
        for (final header in [
          '3600',
          HttpDate.format(DateTime.now().add(const Duration(hours: 1))),
        ]) {
          final adapter = _FakeAdapter(
            failTimes: 1,
            failStatus: 503,
            failHeaders: {'retry-after': header},
          );
          final sw = Stopwatch()..start();

          await _buildDio(
            adapter,
            config: const RetryConfig(
              maxAttempts: 1,
              initialDelay: Duration(milliseconds: 1),
              maxDelay: Duration(milliseconds: 50),
            ),
          ).get('/x');

          expect(adapter.calls, 2);
          expect(sw.elapsed,
              greaterThanOrEqualTo(const Duration(milliseconds: 50)));
          expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
        }
      });

      test('malformed value falls back to backoff', () async {
        final adapter = _FakeAdapter(
          failTimes: 1,
          failStatus: 503,
          failHeaders: {'retry-after': 'soon'},
        );

        final res = await _buildDio(adapter).get('/x');

        expect(res.statusCode, 200);
        expect(adapter.calls, 2);
      });
    });
  });
}
