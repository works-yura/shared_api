import 'options.dart';

/// Field and event names of the JSON wire format spoken over a [Streaming]
/// transport.
///
/// The const default ([StreamingProtocol.standard]) is the format this package
/// has always used:
///
/// ```json
/// {"action": "...", "payload": {...}, "correlation_id": "...", "msg_id": "..."}
/// {"type": "ack", "msg_id": "...", "success": false, "error": "...", "code": 500}
/// {"type": "ping"} / {"type": "pong"}
/// ```
///
/// Pass a customised instance to the drivers, [AckEvent], `MessagingService`
/// and `StreamingErrorInterceptor` to talk to a backend with other names.
class StreamingProtocol {
  /// Field routing incoming messages to a [StreamingEvent.type].
  final String typeField;

  /// Outgoing envelope: action name field.
  final String actionField;

  /// Outgoing envelope: request data field.
  final String payloadField;

  /// Field pairing a request with its response.
  final String correlationIdField;

  /// Field carrying the id of a guaranteed-delivery message.
  final String messageIdField;

  /// [typeField] value of a server acknowledgment.
  final String ackType;

  /// Ack field telling whether the message was processed.
  final String ackSuccessField;

  /// Ack field with the error message of a negative ack.
  final String ackErrorField;

  /// Ack field with the status code of a negative ack.
  final String ackCodeField;

  /// [typeField] value of the client heartbeat.
  final String pingType;

  /// [typeField] value of the server heartbeat reply.
  final String pongType;

  const StreamingProtocol({
    this.typeField = 'type',
    this.actionField = 'action',
    this.payloadField = 'payload',
    this.correlationIdField = 'correlation_id',
    this.messageIdField = 'msg_id',
    this.ackType = 'ack',
    this.ackSuccessField = 'success',
    this.ackErrorField = 'error',
    this.ackCodeField = 'code',
    this.pingType = 'ping',
    this.pongType = 'pong',
  });

  /// The wire format used by default everywhere.
  static const standard = StreamingProtocol();

  /// Heartbeat message sent by the client.
  Map<String, dynamic> get ping => {typeField: pingType};

  /// Type of an incoming message, or null if it has none.
  String? typeOf(Map<String, dynamic> message) {
    final type = message[typeField];
    return type is String ? type : null;
  }

  /// Wraps [options] into the outgoing envelope.
  Map<String, dynamic> envelope(StreamingOptions options) => {
        actionField: options.action,
        payloadField: options.data,
        if (options.correlationId != null)
          correlationIdField: options.correlationId,
        ...options.extras,
      };
}
