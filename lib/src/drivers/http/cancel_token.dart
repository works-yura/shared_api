import 'package:dio/dio.dart' as dio;
import 'package:shared_api/src/core/http/cancel.dart';

/// Dio-specific implementation of [HttpCancelToken].
class DioCancelToken implements HttpCancelToken {
  final dio.CancelToken _token;

  DioCancelToken([dio.CancelToken? token])
      : _token = token ?? dio.CancelToken();

  @override
  void cancel([dynamic reason]) {
    _token.cancel(reason);
  }

  @override
  bool get isCancelled => _token.isCancelled;

  /// Internal access to the underlying Dio token.
  dio.CancelToken get underlying => _token;
}
