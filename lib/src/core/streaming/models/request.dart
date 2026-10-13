import 'package:shared_api/src/core/utils/json.dart';
import '../options.dart';
import 'response.dart';

/// Base class for any streaming request.
abstract class StreamingRequest<R> {
  /// Builds the request options (action + payload)
  StreamingOptions onRequest();

  /// Parses the response into a typed model
  R onResponse(StreamingResponse response);

  /// Called when an exception occurs during request processing
  Exception onException(Exception exception) => exception;
}

/// A request that contains already encoded data (e.g., from Outbox).
///
/// Used to bypass the codec layer when sending pre-serialized packets.
class RawStreamingRequest extends StreamingRequest<void> {
  final dynamic payload;

  RawStreamingRequest(this.payload);

  @override
  StreamingOptions onRequest() => const StreamingOptions(action: 'raw');

  @override
  void onResponse(StreamingResponse response) {}
}

/// Base request with an action.
abstract class BaseStreamingRequest<R> extends StreamingRequest<R> {
  final String action;

  BaseStreamingRequest(this.action);

  /// Override to provide request data
  Map<String, dynamic> get data => {};

  @override
  StreamingOptions onRequest() => StreamingOptions(action: action, data: data);
}

/// A request that processes JSON responses.
abstract class JsonStreamingRequest<R> extends BaseStreamingRequest<R> {
  JsonStreamingRequest(super.action);

  @override
  R onResponse(StreamingResponse response) {
    return onJsonResponse(response.json, response);
  }

  /// Called when a JSON response is received.
  R onJsonResponse(JsonObject json, StreamingResponse response);
}
