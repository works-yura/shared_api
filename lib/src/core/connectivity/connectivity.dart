import 'dart:async';

enum NetworkStatus {
  online,
  offline;

  bool get isOnline => this == NetworkStatus.online;
}

abstract class NetworkConnectivity {
  Stream<NetworkStatus> get status;
  Future<NetworkStatus> get currentStatus;
}
