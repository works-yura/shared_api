import 'package:shared_api/src/core/utils/json.dart';

/// Response wrapper for WebSocket messages.
class StreamingResponse {
  final Map<String, dynamic> data;
  final String? type;

  const StreamingResponse({required this.data, this.type});

  JsonObject get json => JsonObject(data);
}
