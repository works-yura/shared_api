import 'dart:async';
import 'interceptor.dart';
import 'models/request.dart';
import 'events/event.dart';

/// Connection status for any streaming transport.
enum StreamingStatus {
  /// Not connected and not attempting to connect
  disconnected,

  /// Initial connection attempt in progress
  connecting,

  /// Successfully connected and ready for messages
  connected,

  /// Connection lost, attempting to reconnect
  reconnecting
}

extension StreamingStatusX on StreamingStatus {
  bool get isConnected => this == StreamingStatus.connected;
  bool get isDisconnected => this == StreamingStatus.disconnected;
}

/// Abstract interface for any streaming transport (WebSocket, TCP, gRPC, etc.).
///
/// Decouples business logic from specific protocol implementations.
abstract interface class Streaming {
  /// Prepares the payload for transmission (e.g., encodes it).
  ///
  /// This allows the service to store pre-encoded data in the Outbox,
  /// optimizing the sending process and decoupling from specific codecs.
  dynamic prepare(Map<String, dynamic> data);

  /// List of registered interceptors (Middleware)
  List<StreamingInterceptor> get interceptors;

  /// Stream of connection status changes
  Stream<StreamingStatus> get status;

  /// Current connection status
  StreamingStatus get currentStatus;

  /// Whether the client is currently connected
  bool get isConnected;

  /// Initializes connection
  Future<void> connect();

  /// Gracefully closes connection
  Future<void> disconnect();

  /// Fire-and-forget message sending
  void send(StreamingRequest request);

  /// Request-Response message sending with correlation
  Future<R> sendRequest<R>(StreamingRequest<R> request);

  /// Typed event subscription
  Stream<T> on<T>(StreamingEvent<T> eventParser);

  /// Registers a request that should be automatically re-sent on every successful reconnection
  /// (e.g., subscriptions to channels).
  void registerPersistentRequest(StreamingRequest request);

  /// Unregisters a persistent request
  void unregisterPersistentRequest(StreamingRequest request);

  /// Forceful resource cleanup
  void dispose();
}
