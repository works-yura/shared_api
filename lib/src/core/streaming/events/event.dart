import 'package:shared_api/src/core/utils/json.dart';

/// Base class for all incoming WebSocket events.
/// Each event corresponds to a specific message 'type'.
abstract class StreamingEvent<T> {
  /// Unique identifier of the event type (e.g., 'profile_updated')
  String get type;

  /// Logic for parsing data part of the message into domain model
  T onResponse(JsonObject json);
}

/// Helper for subscription-based requests
abstract class StreamingSubscription<T> extends StreamingEvent<T> {
  String get channel;
}
