import 'dart:developer' as developer;
import 'package:shared_api/src/core/exceptions/exception.dart';
import 'package:shared_api/src/core/session/session.dart';

/// Proxy/Observer interface for API events (HTTP and WebSocket).
abstract class HttpObserver {
  /// Called before request is sent
  void onRequest(String path, String method, Map<String, dynamic>? params);

  /// Called on successful response
  void onResponse(String path, Duration duration, int statusCode);

  /// Called on error
  void onError(HttpException exception, [StackTrace? stackTrace]);

  /// Called when session state changes
  void onSessionChanged(HttpState state);

  /// Called on token refresh attempt
  void onTokenRefresh(int attempt, Duration delay, bool isSuccessful);

  /// Called when WebSocket connection status changes
  void onWsStatusChanged(Object status);
}

class CompositeHttpObserver implements HttpObserver {
  final List<HttpObserver> _observers;

  CompositeHttpObserver(this._observers);

  void _notify(void Function(HttpObserver observer) action) {
    for (final observer in _observers) {
      try {
        action(observer);
      } catch (e, stack) {
        developer.log(
          'Error in HttpObserver ${observer.runtimeType}: $e',
          name: 'HttpObserver',
          error: e,
          stackTrace: stack,
        );
      }
    }
  }

  @override
  void onRequest(String path, String method, Map<String, dynamic>? params) {
    _notify((o) => o.onRequest(path, method, params));
  }

  @override
  void onResponse(String path, Duration duration, int statusCode) {
    _notify((o) => o.onResponse(path, duration, statusCode));
  }

  @override
  void onError(HttpException exception, [StackTrace? stackTrace]) {
    _notify((o) => o.onError(exception, stackTrace));
  }

  @override
  void onSessionChanged(HttpState state) {
    _notify((o) => o.onSessionChanged(state));
  }

  @override
  void onTokenRefresh(int attempt, Duration delay, bool isSuccessful) {
    _notify((o) => o.onTokenRefresh(attempt, delay, isSuccessful));
  }

  @override
  void onWsStatusChanged(Object status) {
    _notify((o) => o.onWsStatusChanged(status));
  }
}
