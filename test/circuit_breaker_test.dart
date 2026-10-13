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

const _resetTimeout = Duration(milliseconds: 40);

({Dio dio, _Adapter adapter}) _setup({
  int failureThreshold = 3,
  int successThreshold = 1,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  final adapter = _Adapter();
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(CircuitBreakerInterceptor(
    config: CircuitBreakerConfig(
      failureThreshold: failureThreshold,
      successThreshold: successThreshold,
      resetTimeout: _resetTimeout,
    ),
  ));
  return (dio: dio, adapter: adapter);
}

Future<int?> _status(Dio dio) async {
  try {
    final r = await dio.get<dynamic>('/x');
    return r.statusCode;
  } on DioException catch (e) {
    return e.response?.statusCode;
  }
}

/// Fires a request and returns the DioException (or null on success).
Future<DioException?> _err(Dio dio) async {
  try {
    await dio.get<dynamic>('/x');
    return null;
  } on DioException catch (e) {
    return e;
  }
}

Matcher get _isOpenRejection => isA<DioException>()
    .having((e) => e.type, 'type', DioExceptionType.cancel)
    .having((e) => e.error, 'error', isA<CircuitBreakerOpenException>());

Future<void> _failN(Dio dio, _Adapter a, int n, {int status = 500}) async {
  a.next = (_) => status;
  for (var i = 0; i < n; i++) {
    await _status(dio);
  }
}

Future<void> _waitReset() =>
    Future<void>.delayed(_resetTimeout + const Duration(milliseconds: 20));

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
      await _waitReset();

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
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await _err(t.dio), _isOpenRejection);
      expect(t.adapter.calls, 2);
    });

    test('success closes the circuit (successThreshold = 1)', () async {
      final t = _setup(failureThreshold: 2, successThreshold: 1);
      await _failN(t.dio, t.adapter, 2);
      await _waitReset();

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
      await _waitReset();
      t.adapter.next = (_) => 200;
      await _status(t.dio);

      await _failN(t.dio, t.adapter, 1);
      t.adapter.next = (_) => 200;
      expect(await _err(t.dio), isNull);
    });

    test('failure re-opens immediately and restarts the timeout', () async {
      final t = _setup(failureThreshold: 3);
      await _failN(t.dio, t.adapter, 3);
      await _waitReset();

      await _failN(t.dio, t.adapter, 1); // the test request fails
      expect(t.adapter.calls, 4);

      t.adapter.next = (_) => 200;
      expect(await _err(t.dio), _isOpenRejection);
      expect(t.adapter.calls, 4);

      await _waitReset();
      expect(await _err(t.dio), isNull);
      expect(t.adapter.calls, 5);
    });

    test(
      'successThreshold > 1 eventually closes the circuit',
      () async {
        final t = _setup(failureThreshold: 2, successThreshold: 2);
        await _failN(t.dio, t.adapter, 2);
        await _waitReset();

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
        await _waitReset();

        await _failN(t.dio, t.adapter, 1, status: 404); // test request
        t.adapter.next = (_) => 200;
        expect(await _err(t.dio), isNull);
      },
    );
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
