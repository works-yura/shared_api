import 'package:dio/dio.dart';
import 'package:shared_api/src/core/exceptions/error_envelope.dart';
import 'package:shared_api/src/core/exceptions/exception.dart';

class DioErrorHandler {
  /// Maps [error] to an [HttpException]; [envelope] reads the error body.
  static HttpException handle(
    DioException error, {
    ErrorEnvelopeParser envelope = const ErrorEnvelopeParser(),
  }) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout =>
        HttpException.timeout(),
      DioExceptionType.cancel => HttpException.cancel(),
      DioExceptionType.badCertificate => HttpException.certificate(),
      DioExceptionType.connectionError => HttpException.connection(),
      DioExceptionType.badResponse => _handleBadResponse(error, envelope),
      DioExceptionType.unknown => HttpException.unknown(
          message: error.message ?? error.error?.toString()),
    };
  }

  static HttpException _handleBadResponse(
      DioException error, ErrorEnvelopeParser envelope) {
    final response = error.response;
    if (response == null) return HttpException.unknown();

    return HttpException.response(
      status: response.statusCode,
      message: envelope.message(response.data) ?? error.message,
      data: response.data,
      headers: response.headers.map,
      envelope: envelope,
    );
  }
}
