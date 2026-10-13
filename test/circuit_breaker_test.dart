import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/drivers/http/interceptors/circuit_breaker.dart';

/// Scripted adapter: [next] decides what each call does (status code or throw).
class _Adapter implements HttpClientAdapter {
  int calls = 0;

  /// Return an HTTP status, or throw a DioException to simulate network errors.
  int Function(RequestOptions options) next = (_) => 200;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    final status = next(options);
    return ResponseBody.fromString('{}', status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

const _resetTimeout = Duration(seconds: 30);

/// Fake clock: tests advance time explicitly instead of sleeping.
class _Clock {
  DateTime value = DateTime(2026);
  DateTime call() => value;
  void advance(Duration d) => value = value.add(d);
}

({Dio dio, _Adapter adapter, _Clock clock}) _setup({
  int failureThreshold = 3,
  int successThreshold = 1,
  bool Function(DioException err)? isFailure,
  String Function(RequestOptions options)? keyOf,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  final adapter = _Adapter();
  final clock = _Clock();
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(CircuitBreakerInterceptor(
    config: CircuitBreakerConfig(
      failureThreshold: failureThreshold,
      successThreshold: successThreshold,
      resetTimeout: _resetTimeout,
    ),
    isFailure: isFailure,
    keyOf: keyOf,
    now: clock.call,
  ));
  return (dio: dio, adapter: adapter, clock: clock);
}

Future<int?> _status(Dio dio, [String url = '/x']) async {
  try {
    final r = await dio.get<dynamic>(url);
    return r.statusCode;
  } on DioException catch (e) {
    return e.response?.statusCode;
  }
}

/// Fires a request and returns the DioException (or null on success).
Future<DioException?> _err(Dio dio, [String url = '/x']) async {
  try {
    await dio.get<dynamic>(url);
    return null;
  } on DioException catch (e) {
    return e;
  }
}

Matcher get _isOpenRejection => isA<DioException>()
    .having((e) => e.type, 'type', DioExceptionType.cancel)
    .having((e) => e.error, 'error', isA<CircuitBreakerOpenException>());

Future<void> _failN(Dio dio, _Adapter a, int n,
    {int status = 500, String url = '/x'}) async {
  a.next = (_) => status;
  for (var i = 0; i < n; i++) {
    await _status(dio, url);
  }
}

void _waitReset(_Clock clock) =>
    clock.advance(_resetTimeout + const Duration(milliseconds: 1));

void main() {
  group('closed', () {
    test('passes requests through to the adapter', () async {
      final t = _setup();
      expect(await _status(t.dio), 200);
      expect(await _status(t.dio), 200);
      expect(t.adapter.calls, 2);
    });

    test('stays closed below failure threshold', () async {
      final t = _setup(failureThreshold: 3);
      await _failN(t.dio, t.adapter, 2);
      t.adapter.next = (_) => 200;
      expect(await _err(t.dio), isNull);
      expect(t.adapter.calls, 3);
    });

    test('success resets the consecutive failure count', () async {
      final t = _setup(failureThreshold: 3);
      await _failN(t.dio, t.adapter, 2);
      t.adapter.next = (_) => 200;
      await _status(t.dio);
      await _failN(t.dio, t.adapter, 2);

      // 2 + 2 failures separated by a success: still closed.
      t.adapter.next = (_) => 200;
      expect(await _err(t.dio), isNull);
    });
  });

  group('opening', () {
    test('opens after threshold and fails fast without hitting adapter',
        () async {
      final t = _setup(failureThreshold: 3);
      await _failN(t.dio, t.adapter, 3);
      expect(t.adapter.calls, 3);

      t.adapter.next = (_) => 200;
      for (var i = 0; i < 5; i++) {
        expect(await _err(t.dio), _isOpenRejection);
      }
      expect(t.adapter.calls, 3);
    });

    test('rejection message is the CircuitBreakerOpenException', () {
      expect(
          CircuitBreakerOpenException().toString(), contains('Circuit Open'));
    });

    test('default config values', () {
      const c = CircuitBreakerConfig();
      expect(c.failureThreshold, 5);
      expect(c.successThreshold, 3);
      expect(c.resetTimeout, const Duration(seconds: 30));
    });
  });

  group('which errors count as failures', () {
    for (final status in [500, 502, 503, 504]) {
      test('$status counts', () async {
        final t = _setup(failureThreshold: 2);
        await _failN(t.dio, t.adapter, 2, status: status);
        expect(await _err(t.dio), _isOpenRejection);
      });
    }

    for (final status in [400, 401, 403, 404, 409, 422, 429]) {
      test('$status does not count', () async {
        final t = _setup(failureThreshold: 2);
        await _failN(t.dio, t.adapter, 5, status: status);
        t.adapter.next = (_) => 200;
        expect(await _err(t.dio), isNull);
        expect(t.adapter.calls, 6);
      });
    }

    for (final type in [
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      test('${type.name} counts', () async {
        final t = _setup(failureThreshold: 2);
        t.adapter.next =
            (o) => throw DioException(requestOptions: o, type: type);
        await _err(t.dio);
        await _err(t.dio);
        t.adapter.next = (_) => 200;
        expect(await _err(t.dio), _isOpenRejection);
        expect(t.adapter.calls, 2);
      });
    }

    for (final type in [
      DioExceptionType.cancel,
      DioExceptionType.unknown,
      DioExceptionType.badCertificate,
    ]) {
      test('${type.name} does not count', () async {
        final t = _setup(failureThreshold: 2);
        t.adapter.next =
            (o) => throw DioException(requestOptions: o, type: type);
        for (var i = 0; i < 4; i++) {
          await _err(t.dio);
        }
        t.adapter.next = (_) => 200;
        expect(await _err(t.dio), isNull);
      });
    }

    test('4xx in closed state does not reset failure count either', () async {
      final t = _setup(failureThreshold: 2);
      await _failN(t.dio, t.adapter, 1);
      await _failN(t.dio, t.adapter, 1, status: 404);
      await _failN(t.dio, t.adapter, 1);
      expect(await _err(t.dio), _isOpenRejection);
    });
  });

  group('half-open', () {
    test('after reset timeout lets exactly one test request through', () async {
      final t = _setup(failureThreshold: 2);
      await _failN(t.dio, t.adapter, 2);
      _waitReset(t.clock);

      // Hold the test request open so concurrent ones see half-open.
      final gate = Completer<void>();
      t.adapter.next = (_) => 200;
      final dio = t.dio;
      final adapter = t.adapter;
      final slow = _SlowAdapter(adapter, gate.future);
      dio.httpClientAdapter = slow;

      final first = _err(dio);
      await Future<void>.delayed(Duration.zero);
      final second = await _err(dio);
      expect(second, _isOpenRejection);

      gate.complete();
      expect(await first, isNull);
      expect(adapter.calls, 3);
    });

    test('still open before reset timeout elapses', () async {
      final t = _setup(failureThreshold: 2);
      await _failN(t.dio, t.adapter, 2);
      t.clock.advance(const Duration(seconds: 29));
      expect(await _err(t.dio), _isOpenRejection);
      expect(t.adapter.calls, 2);
    });

    test('success closes the circuit (successThreshold = 1)', () async {
      final t = _setup(failureThreshold: 2, successThreshold: 1);
      await _failN(t.dio, t.adapter, 2);
      _waitReset(t.clock);

      t.adapter.next = (_) => 200;
      expect(await _err(t.dio), isNull);
      // Closed: everything flows again.
      for (var i = 0; i < 3; i++) {
        expect(await _err(t.dio), isNull);
      }
      expect(t.adapter.calls, 6);
    });

    test('closed again after recovery needs full threshold to re-open',
        () async {
      final t = _setup(failureThreshold: 2, successThreshold: 1);
      await _failN(t.dio, t.adapter, 2);
      _waitReset(t.clock);
      t.adapter.next = (_) => 200;
      await _status(t.dio);

      await _failN(t.dio, t.adapter, 1);
      t.adapter.next = (_) => 200;
      expect(await _err(t.dio), isNull);
    });

    test('failure re-opens immediately and restarts the timeout', () async {
      final t = _setup(failureThreshold: 3);
      await _failN(t.dio, t.adapter, 3);
      _waitReset(t.clock);

      await _failN(t.dio, t.adapter, 1); // the test request fails
      expect(t.adapter.calls, 4);

      t.adapter.next = (_) => 200;
      expect(await _err(t.dio), _isOpenRejection);
      expect(t.adapter.calls, 4);

      _waitReset(t.clock);
      expect(await _err(t.dio), isNull);
      expect(t.adapter.calls, 5);
    });

    test(
      'successThreshold > 1 eventually closes the circuit',
      () async {
        final t = _setup(failureThreshold: 2, successThreshold: 2);
        await _failN(t.dio, t.adapter, 2);
        _waitReset(t.clock);

        t.adapter.next = (_) => 200;
        expect(await _err(t.dio), isNull); // 1st test success
        expect(await _err(t.dio), isNull); // 2nd should be allowed
        expect(await _err(t.dio), isNull);
      },
    );

    test(
      'non-system error (4xx) on the half-open test request does not wedge '
      'the breaker',
      () async {
        final t = _setup(failureThreshold: 2);
        await _failN(t.dio, t.adapter, 2);
        _waitReset(t.clock);

        await _failN(t.dio, t.adapter, 1, status: 404); // test request
        t.adapter.next = (_) => 200;
        expect(await _err(t.dio), isNull);
      },
    );
  });

  group('isFailure', () {
    test('custom predicate decides what counts', () async {
      // Treat 429 as a failure, and 5xx as not.
      final t = _setup(
        failureThreshold: 2,
        isFailure: (e) => e.response?.statusCode == 429,
      );
      await _failN(t.dio, t.adapter, 3, status: 500);
      t.adapter.next = (_) => 200;
      expect(await _err(t.dio), isNull);

      await _failN(t.dio, t.adapter, 2, status: 429);
      expect(await _err(t.dio), _isOpenRejection);
    });

    test('defaultIsFailure can be composed', () async {
      final t = _setup(
        failureThreshold: 2,
        isFailure: (e) =>
            CircuitBreakerInterceptor.defaultIsFailure(e) ||
            e.response?.statusCode == 429,
      );
      await _failN(t.dio, t.adapter, 1, status: 500);
      await _failN(t.dio, t.adapter, 1, status: 429);
      expect(await _err(t.dio), _isOpenRejection);
    });
  });

  group('keyOf', () {
    test('default: one global circuit for all hosts', () async {
      final t = _setup(failureThreshold: 2);
      await _failN(t.dio, t.adapter, 2, url: 'https://a.test/x');
      t.adapter.next = (_) => 200;
      expect(await _err(t.dio, 'https://b.test/x'), _isOpenRejection);
    });

    test('per-host circuits are independent', () async {
      final t = _setup(failureThreshold: 2, keyOf: (o) => o.uri.host);
      await _failN(t.dio, t.adapter, 2, url: 'https://a.test/x');
      t.adapter.next = (_) => 200;

      expect(await _err(t.dio, 'https://a.test/x'), _isOpenRejection);
      expect(await _err(t.dio, 'https://b.test/x'), isNull);

      // Half-open probe on a.test does not block b.test.
      _waitReset(t.clock);
      expect(await _err(t.dio, 'https://a.test/x'), isNull);
      expect(await _err(t.dio, 'https://b.test/x'), isNull);
    });
  });
}

/// Wraps an adapter and delays every response until [gate] completes.
class _SlowAdapter implements HttpClientAdapter {
  final _Adapter inner;
  final Future<void> gate;
  _SlowAdapter(this.inner, this.gate);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await gate;
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}
