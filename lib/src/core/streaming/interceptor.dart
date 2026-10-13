import 'options.dart';
import 'models/response.dart';
import 'client.dart';

/// Interceptor for streaming events, allowing middleware logic like logging,
/// analytics, and error mapping.
abstract class StreamingInterceptor {
  const StreamingInterceptor();

  /// Called before sending a request
  void onRequest(StreamingOptions options) {}

  /// Called when a message (event or response) is received
  void onResponse(StreamingResponse response) {}

  /// Called when the connection status changes
  void onStatusChanged(StreamingStatus status) {}

  /// Called when an error occurs
  void onError(Object error, [StackTrace? stackTrace]) {}
}
