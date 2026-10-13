import 'package:dio/dio.dart';

enum CircuitState { closed, open, halfOpen }

class CircuitBreakerInterceptor extends Interceptor {
  final CircuitBreakerConfig config;

  // State management
  CircuitState _state = CircuitState.closed;
  int _failureCount = 0;
  int _successCount = 0;
  DateTime? _lastFailureTime;
  bool _isTestingHalfOpen = false;

  CircuitBreakerInterceptor({
    this.config = const CircuitBreakerConfig(),
  });

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (_state == CircuitState.open) {
      if (_lastFailureTime != null &&
          DateTime.now().difference(_lastFailureTime!) > config.resetTimeout) {
        _transitionToHalfOpen();
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

    if (_state == CircuitState.halfOpen) {
      if (_isTestingHalfOpen) {
        // We already have a request testing the connection. Fail others fast.
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.cancel,
            error: CircuitBreakerOpenException(),
          ),
        );
      }
      _isTestingHalfOpen = true; // This request is the chosen one!
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _recordSuccess();
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (_isSystemFailure(err)) {
      _recordFailure();
    }
    handler.next(err);
  }

  void _recordSuccess() {
    if (_state == CircuitState.halfOpen) {
      _successCount++;
      if (_successCount >= config.successThreshold) {
        _transitionToClosed();
      }
    } else {
      // In closed state, we might want to reset failure count periodically
      // but for simplicity, we reset it on successful call if we had failures?
      // Or just keep it. Standard implementation typically uses a time window.
      // Here we implement a simple consecutive failure count for simplicity.
      _failureCount = 0;
    }
  }

  void _recordFailure() {
    _failureCount++;
    _lastFailureTime = DateTime.now();

    if (_state == CircuitState.closed &&
        _failureCount >= config.failureThreshold) {
      _transitionToOpen();
    } else if (_state == CircuitState.halfOpen) {
      _transitionToOpen();
    }
  }

  void _transitionToOpen() {
    _state = CircuitState.open;
    _isTestingHalfOpen = false;
    print('CircuitBreaker: OPEN'); // Consider using a logger
  }

  void _transitionToHalfOpen() {
    _state = CircuitState.halfOpen;
    _successCount = 0;
    _isTestingHalfOpen = false; // Ready for a test request
    print('CircuitBreaker: HALF-OPEN');
  }

  void _transitionToClosed() {
    _state = CircuitState.closed;
    _failureCount = 0;
    _successCount = 0;
    _isTestingHalfOpen = false;
    print('CircuitBreaker: CLOSED');
  }

  bool _isSystemFailure(DioException err) {
    // Network errors or 5xx server errors
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
