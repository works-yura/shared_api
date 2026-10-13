import 'dart:async';
import '/src/core/core.dart';

class BasicNetworkConnectivity implements NetworkConnectivity {
  final _controller = StreamController<NetworkStatus>.broadcast();

  // Default to online
  NetworkStatus _cachedStatus = NetworkStatus.online;

  @override
  Stream<NetworkStatus> get status => _controller.stream;

  @override
  Future<NetworkStatus> get currentStatus async => _cachedStatus;

  // Method to simulate status change
  void updateStatus(NetworkStatus newStatus) {
    _cachedStatus = newStatus;
    _controller.add(newStatus);
  }
}
