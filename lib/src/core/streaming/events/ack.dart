import 'package:shared_api/src/core/utils/json.dart';
import '../protocol.dart';
import 'event.dart';

/// Server acknowledgment response for a sent message.
class AckResponse {
  /// The message ID that was acknowledged
  final String messageId;

  /// Whether the server successfully processed the message
  final bool isSuccess;

  /// Optional error message if processing failed
  final String? error;

  AckResponse({
    required this.messageId,
    required this.isSuccess,
    this.error,
  });
}

/// Parses server acks; names come from [protocol].
class AckEvent extends StreamingEvent<AckResponse> {
  final StreamingProtocol protocol;

  AckEvent([this.protocol = StreamingProtocol.standard]);

  @override
  String get type => protocol.ackType;

  @override
  AckResponse onResponse(JsonObject json) {
    return AckResponse(
      messageId: json.required<String>(protocol.messageIdField),
      isSuccess: json.as<bool>(protocol.ackSuccessField, true),
      error: json.as<String?>(protocol.ackErrorField, null),
    );
  }
}
