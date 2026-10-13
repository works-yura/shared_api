import 'package:shared_api/src/core/utils/json.dart';
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

class AckEvent extends StreamingEvent<AckResponse> {
  @override
  String get type => 'ack';

  @override
  AckResponse onResponse(JsonObject json) {
    return AckResponse(
      messageId: json.required<String>('msg_id'),
      isSuccess: json.as<bool>('success', true),
      error: json.as<String?>('error', null),
    );
  }
}
