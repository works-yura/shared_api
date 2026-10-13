import 'dart:developer' as developer;
import 'package:dio/dio.dart';

enum CircuitState { closed, open, halfOpen }

/// Fails fast while a backend is unhealthy instead of piling up requests.
///
/// After [CircuitBreakerConfig.failureThreshold] consecutive failures the
/// circuit opens and rejects requests with [CircuitBreakerOpenException].
/// After [CircuitBreakerConfig.resetTimeout] one probe request is let through
/// (half-open); [CircuitBreakerConfig.successThreshold] successes close it.
///
/// - [isFailure] decides which errors count. Defaults to [defaultIsFailure]:
///   network errors and 5xx.
/// - [keyOf] splits requests into independent circuits, e.g.
///   `(o) => o.uri.host` for one circuit per host. Defaults to one global
///   circuit for all requests.
/// - [now] is the clock, injectable for tests.
class CircuitBreakerInterceptor extends Interceptor {
  final CircuitBreakerConfig config;
  final bool Function(DioException err) isFailure;
  final String Function(RequestOptions options)? keyOf;
  final DateTime Function() now;

  final Map<String, _Circuit> _circuits = {};

  CircuitBreakerInterceptor({
    this.config = const CircuitBreakerConfig(),
    bool Function(DioException err)? isFailure,
    this.keyOf,
    this.now = DateTime.now,
  }) : isFailure = isFailure ?? defaultIsFailure;

  /// Network errors or 5xx server errors.
  static bool defaultIsFailure(DioException err) {
    if (err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout ||
        err.type == DioExceptionType.receiveTimeout ||
        err.type == DioExceptionType.connectionError) {
      return true;
    }
    if (err.type == DioExceptionType.badResponse) {
      final status = err.response?.statusCode;
      return status != null && status >= 500;
    }
    return false;
  }

  _Circuit _circuitFor(RequestOptions options) {
    final key = keyOf?.call(options) ?? '';
    return _circuits.putIfAbsent(key, () => _Circuit(key));
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final circuit = _circuitFor(options);

    if (circuit.state == CircuitState.open) {
      if (circuit.lastFailureTime != null &&
          now().difference(circuit.lastFailureTime!) > config.resetTimeout) {
        circuit.transitionToHalfOpen();
      } else {
        // Fast fail
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            error: CircuitBreakerOpenException(),
          ),
        );
      }
    }

    if (circuit.state == CircuitState.halfOpen) {
      if (circuit.isTestingHalfOpen) {
        // We already have a request testing the connection. Fail others fast.
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            error: CircuitBreakerOpenException(),
          ),
        );
      }
      circuit.isTestingHalfOpen = true; // This request is the chosen one!
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _circuitFor(response.requestOptions).recordSuccess(config);
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final circuit = _circuitFor(err.requestOptions);
    if (isFailure(err)) {
      circuit.recordFailure(config, now());
    } else if (circuit.state == CircuitState.halfOpen) {
      if (err.type == DioExceptionType.badResponse) {
        // A 4xx means the server is reachable and healthy enough to answer.
        circuit.recordSuccess(config);
      } else {
        // Cancelled / unknown probe proved nothing: let the next request probe.
        circuit.isTestingHalfOpen = false;
      }
    }
    handler.next(err);
  }
}

/// State of a single circuit.
class _Circuit {
  final String key;

  CircuitState state = CircuitState.closed;
  int failureCount = 0;
  int successCount = 0;
  DateTime? lastFailureTime;
  bool isTestingHalfOpen = false;

  _Circuit(this.key);

  void recordSuccess(CircuitBreakerConfig config) {
    if (state == CircuitState.halfOpen) {
      successCount++;
      // Probe finished: allow the next request to probe.
      isTestingHalfOpen = false;
      if (successCount >= config.successThreshold) {
        transitionToClosed();
      }
    } else {
      // Simple consecutive failure count: any success resets it.
      failureCount = 0;
    }
  }

  void recordFailure(CircuitBreakerConfig config, DateTime at) {
    failureCount++;
    lastFailureTime = at;

    if (state == CircuitState.closed &&
        failureCount >= config.failureThreshold) {
      transitionToOpen();
    } else if (state == CircuitState.halfOpen) {
      transitionToOpen();
    }
  }

  void transitionToOpen() {
    state = CircuitState.open;
    isTestingHalfOpen = false;
    _log('OPEN');
  }

  void transitionToHalfOpen() {
    state = CircuitState.halfOpen;
    successCount = 0;
    isTestingHalfOpen = false; // Ready for a test request
    _log('HALF-OPEN');
  }

  void transitionToClosed() {
    state = CircuitState.closed;
    failureCount = 0;
    successCount = 0;
    isTestingHalfOpen = false;
    _log('CLOSED');
  }

  void _log(String state) => developer.log(
        key.isEmpty ? state : '$state ($key)',
        name: 'CircuitBreaker',
      );
}

class CircuitBreakerConfig {
  final int failureThreshold;
  final int successThreshold;
  final Duration resetTimeout;

  const CircuitBreakerConfig({
    this.failureThreshold = 5,
    this.successThreshold = 3,
    this.resetTimeout = const Duration(seconds: 30),
  });
}

class CircuitBreakerOpenException implements Exception {
  @override
  String toString() =>
      'CircuitBreakerOpenException: Service is unavailable (Circuit Open)';
}
