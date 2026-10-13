import 'dart:async';
import '/src/core/core.dart';

/// Service for reliable messaging with guaranteed delivery over any [Streaming].
///
/// Manages the outbox queue, listens for ACK events from the server,
/// and coordinates message retries on reconnection.
class MessagingService {
  final Streaming _client;
  final Outbox _outbox;

  /// Wire names of the envelope, message id and acks.
  final StreamingProtocol protocol;

  StreamSubscription? _ackSubscription;

  MessagingService({
    required Streaming streaming,
    required Outbox outbox,
    this.protocol = StreamingProtocol.standard,
  })  : _client = streaming,
        _outbox = outbox;

  /// Initializes the ACK listener.
  void init() {
    _ackSubscription = _client.on(AckEvent(protocol)).listen(_handleAck);
  }

  void _handleAck(AckResponse ack) {
    if (ack.isSuccess) {
      _outbox.delete(ack.messageId);
    }
  }

  /// Sends a message with guaranteed delivery.
  Future<String> send(StreamingRequest request) async {
    final messageId = DeviceId.generate(16);
    final options = request.onRequest();

    // Merge the message id into the envelope
    final payloadMap = options.toJson(protocol)
      ..[protocol.messageIdField] = messageId;

    dynamic finalPayload = _client.prepare(payloadMap);

    final entry = OutboxEntry(id: messageId, payload: finalPayload);
    await _outbox.save(entry);

    if (_client.isConnected) {
      _client.send(RawStreamingRequest(finalPayload));
    }

    return messageId;
  }

  /// Flushes all pending messages after reconnection.
  Future<void> flushPending() async {
    if (!_client.isConnected) return;

    final pending = await _outbox.getAll();
    for (final entry in pending) {
      entry.retryCount++;
      await _outbox.update(entry);
      _client.send(RawStreamingRequest(entry.payload));
    }
  }

  Future<int> get pendingCount async {
    final all = await _outbox.getAll();
    return all.length;
  }

  void dispose() {
    _ackSubscription?.cancel();
  }
}
