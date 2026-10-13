import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '/src/core/core.dart';

/// [NetworkConnectivity] backed by `connectivity_plus`.
///
/// Notes:
/// - "online" here means the device has an active network *interface*
///   (Wi-Fi, mobile, ethernet, vpn). It does NOT guarantee reachability
///   of the API — a captive-portal hotspot or DNS dropout will still report
///   online. For the universal error-state UX we treat that as good enough:
///   the actual API call fails, the error widget shows, and when the device
///   eventually has a working connection the next retry succeeds.
/// - The stream emits only on actual changes (we de-dupe).
class RealNetworkConnectivity implements NetworkConnectivity {
  final Connectivity _connectivity;
  final _controller = StreamController<NetworkStatus>.broadcast();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  NetworkStatus _cachedStatus = NetworkStatus.online;
  bool _initialized = false;

  RealNetworkConnectivity({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity() {
    _start();
  }

  @override
  Stream<NetworkStatus> get status => _controller.stream;

  @override
  Future<NetworkStatus> get currentStatus async {
    if (!_initialized) {
      try {
        final results = await _connectivity.checkConnectivity();
        _cachedStatus = _toStatus(results);
        _initialized = true;
      } catch (_) {
        // Some platforms (rare desktop/CI) fail the check — assume online so
        // we don't block legitimate traffic.
        _cachedStatus = NetworkStatus.online;
      }
    }
    return _cachedStatus;
  }

  void _start() {
    _subscription = _connectivity.onConnectivityChanged.listen(
      (results) {
        final next = _toStatus(results);
        _initialized = true;
        if (next == _cachedStatus) return;
        _cachedStatus = next;
        _controller.add(next);
      },
      onError: (_) {
        // Swallow stream errors — connectivity can briefly throw on Android
        // during airplane-mode toggles. We just keep the last known state.
      },
    );
  }

  NetworkStatus _toStatus(List<ConnectivityResult> results) {
    final hasInterface = results.any(
      (r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn,
    );
    return hasInterface ? NetworkStatus.online : NetworkStatus.offline;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }
}
