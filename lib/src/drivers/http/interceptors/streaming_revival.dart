import 'package:dio/dio.dart';
import 'package:shared_api/src/core/streaming/client.dart';

/// Wakes the WebSocket on HTTP activity when the streaming layer isn't healthy.
///
/// Why: app sitting idle in foreground can lose its TCP socket (Wi-Fi blip,
/// server idle timeout, mobile network handoff) without the OS firing a
/// background→foreground lifecycle event. Without this hook, the WS stays
/// dead until the next scheduled token refresh (~13 min) — meanwhile real-time
/// events (matches, messages) silently drop.
///
/// Strategy: an HTTP response can restart a fully stopped socket. An active
/// connection attempt or backoff timer owns its own retries; calling connect
/// again on every response would reset that timer and create a request loop.
class StreamingRevivalInterceptor extends InterceptorsWrapper {
  final Streaming streaming;

  StreamingRevivalInterceptor({required this.streaming});

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    _maybeRevive();
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    _maybeRevive();
    handler.next(err);
  }

  void _maybeRevive() {
    if (streaming.currentStatus == StreamingStatus.disconnected) {
      streaming.connect();
    }
  }
}
