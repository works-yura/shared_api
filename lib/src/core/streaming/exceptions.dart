/// Base exception for streaming operations.
class StreamingException implements Exception {
  final String message;
  const StreamingException(this.message);
  @override
  String toString() => 'StreamingException: $message';
}

class StreamingNotConnectedException extends StreamingException {
  StreamingNotConnectedException() : super('WebSocket is not connected');
}

class StreamingDisconnectedException extends StreamingException {
  StreamingDisconnectedException()
      : super('WebSocket disconnected while waiting for response');
}

class StreamingTimeoutException extends StreamingException {
  final String correlationId;
  StreamingTimeoutException(this.correlationId)
      : super('Request timed out: $correlationId');
}

class StreamingDisposedException extends StreamingException {
  StreamingDisposedException() : super('WebSocket client was disposed');
}
