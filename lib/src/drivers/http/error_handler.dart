import 'package:dio/dio.dart';
import 'package:shared_api/src/core/exceptions/exception.dart';

class DioErrorHandler {
  static HttpException handle(DioException error) {
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout =>
        HttpException.timeout(),
      DioExceptionType.cancel => HttpException.cancel(),
      DioExceptionType.badCertificate => HttpException.certificate(),
      DioExceptionType.connectionError => HttpException.connection(),
      DioExceptionType.badResponse => _handleBadResponse(error),
      DioExceptionType.unknown => HttpException.unknown(
          message: error.message ?? error.error?.toString()),
    };
  }

  static HttpException _handleBadResponse(DioException error) {
    final response = error.response;
    if (response == null) return HttpException.unknown();

    String? message = error.message;
    if (response.data is Map && (response.data as Map).containsKey('message')) {
      final msg = (response.data as Map)['message'];
      if (msg is String && msg.isNotEmpty) {
        message = msg;
      } else if (msg is List && msg.isNotEmpty) {
        message = msg.join('\n');
      }
    }

    return HttpException.response(
      status: response.statusCode,
      message: message,
      data: response.data,
      headers: response.headers.map,
    );
  }
}
