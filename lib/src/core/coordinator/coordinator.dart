import 'dart:async';
import 'package:shared_api/src/core/session/session.dart';
import 'package:shared_api/src/core/connectivity/connectivity.dart';
import 'package:shared_api/src/core/streaming/client.dart';

import 'package:shared_api/src/core/utils/observer.dart';
import 'package:shared_api/src/core/utils/retry_config.dart';

/// Abstract base for session lifecycle and background processes coordination.
///
/// This class lives in `core` and depends only on core abstractions.
/// Practical implementation (orchestrating concrete clients) should be done in higher layers.
abstract class Coordinator<S extends HttpState> {
  final HttpSession<S> _session;
  final NetworkConnectivity _connectivity;
  final Streaming? _streaming;
  final List<HttpObserver> _observers;
  final RetryConfig _retry;

  Timer? _refreshTimer;
  int _refreshAttempts = 0;
  bool _disposed = false;
  NetworkStatus _currentStatus = NetworkStatus.online;

  StreamSubscription? _sessionSub;
  StreamSubscription? _networkSub;
  StreamSubscription? _streamingStatusSub;

  Coordinator({
    required HttpSession<S> session,
    required NetworkConnectivity connectivity,
    Streaming? streaming,
    List<HttpObserver>? observers,
    RetryConfig retry = const RetryConfig(),
  })  : _session = session,
        _connectivity = connectivity,
        _streaming = streaming,
        _observers = observers ?? [],
        _retry = retry;

  void setup() {
    _networkSub = _connectivity.status.listen(_onNetworkChanged);
    _sessionSub = _session.status.listen(_onSessionChanged);

    // Monitor Streaming status for automatic outbox flush
    _streamingStatusSub = _streaming?.status.listen(_onStreamingStatusChanged);

    // Cold-start trigger: read() will populate the cache and emit to the
    // broadcast stream. We rely on the listener above to react — DO NOT also
    // pipe the result through .then() or _onSessionChanged fires twice
    // and cascades into a streaming reconnect loop.
    _session.read();
  }

  // ==========================================================================
  // Network Status Handling
  // ==========================================================================

  void _onNetworkChanged(NetworkStatus status) {
    final wasOffline = _currentStatus == NetworkStatus.offline;
    _currentStatus = status;

    if (status.isOnline) {
      if (wasOffline) {
        onNetworkRestored();
      }
    } else {
      // Disconnect when network goes offline
      _streaming?.disconnect();
    }
  }

  /// Hook called when network is restored.
  /// Should be overridden to handle state-specific reconnection logic.
  Future<void> onNetworkRestored();

  // ==========================================================================
  // Session Status Handling
  // ==========================================================================

  void _onSessionChanged(S? state) {
    stopTimer();

    for (var o in _observers) {
      if (state != null) o.onSessionChanged(state);
    }

    onSessionChanged(state);
  }

  /// Hook called when session state changes.
  void onSessionChanged(S? state);

  // ==========================================================================
  // Streaming Status Handling
  // ==========================================================================

  void _onStreamingStatusChanged(StreamingStatus status) {
    onStreamingStatusChanged(status);

    for (var o in _observers) {
      o.onWsStatusChanged(status);
    }
  }

  /// Hook called when streaming status changes.
  void onStreamingStatusChanged(StreamingStatus status);

  // ==========================================================================
  // Token Refresh Helpers
  // ==========================================================================

  void scheduleRefresh(Duration delay, Future<bool> Function() refreshAction) {
    stopTimer();

    if (_disposed || _currentStatus == NetworkStatus.offline) return;

    if (delay == Duration.zero) {
      _performRefresh(refreshAction);
    } else {
      _refreshTimer = Timer(delay, () => _performRefresh(refreshAction));
    }
  }

  Future<void> _performRefresh(Future<bool> Function() refreshAction) async {
    try {
      final isSuccessful = await refreshAction();
      // The coordinator may have been disposed while the request was in flight.
      if (_disposed) return;
      if (isSuccessful) {
        _refreshAttempts = 0;
        for (var o in _observers)
          o.onTokenRefresh(_refreshAttempts, Duration.zero, true);
      } else {
        handleRefreshFailure(refreshAction);
      }
    } catch (e) {
      if (_disposed) return;
      handleRefreshFailure(refreshAction);
    }
  }

  /// Default retry logic for refresh failures.
  void handleRefreshFailure(Future<bool> Function() refreshAction) {
    if (_disposed) return;

    for (var o in _observers)
      o.onTokenRefresh(_refreshAttempts, Duration.zero, false);

    if (_currentStatus == NetworkStatus.offline) return;

    if (_refreshAttempts < _retry.maxAttempts) {
      _refreshAttempts++;
      final retryDelay = _retry.getDelayForAttempt(_refreshAttempts);
      _refreshTimer = Timer(retryDelay, () => _performRefresh(refreshAction));
    } else {
      onRefreshMaxAttemptsReached();
    }
  }

  /// Hook called when max refresh attempts are reached.
  void onRefreshMaxAttemptsReached();

  void stopTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void dispose() {
    _disposed = true;
    _sessionSub?.cancel();
    _networkSub?.cancel();
    _streamingStatusSub?.cancel();
    stopTimer();
    _streaming?.dispose();
  }

  // Getters for child classes
  HttpSession<S> get session => _session;
  Streaming? get streaming => _streaming;
  bool get isOnline => _currentStatus.isOnline;
}
