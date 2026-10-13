import 'dart:io';
import 'package:shared_api/shared_api.dart';

/// Interceptor that maps raw WebSocket errors and server Negative ACKs
/// into your domain's [HttpException] models.
class StreamingErrorInterceptor extends StreamingInterceptor {
  const StreamingErrorInterceptor();

  @override
  void onResponse(StreamingResponse response) {
    final json = response.json;

    // Check for Negative ACK (success: false)
    if (json.as<String>('type', '') == 'ack' &&
        !json.as<bool>('success', true)) {
      final errorMessage = json.as<String>('error', 'Unknown WebSocket Error');
      final statusCode = json.as<int>('code', 500);

      // Map to HttpResponseException for compatibility with your existing error handling flow
      throw HttpException.response(
        status: statusCode,
        message: errorMessage,
        headers: {},
        data: response.data,
      );
    }
  }

  @override
  void onError(Object error, [StackTrace? stackTrace]) {
    // Mapping system errors to your domain exceptions
    if (error is SocketException) {
      throw HttpException.connection();
    } else if (error is HttpException) {
      // Re-throw if already mapped
      throw error;
    } else if (error is StreamingException) {
      // Map basic WS exceptions to common HttpExceptions if needed
      throw HttpException(
        message: error.message,
        originalError: error,
      );
    }
  }
}
