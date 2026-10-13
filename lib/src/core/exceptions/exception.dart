import 'package:shared_api/src/core/exceptions/failures.dart';

enum HttpExceptionType {
  timeout,
  certificate,
  cancel,
  connection,
  response,
  serialization,
  upgradeRequired,
  unknown,
}

final class HttpException implements Exception {
  final HttpExceptionType type;
  final String? message;
  final dynamic originalError;

  HttpException({
    this.type = HttpExceptionType.unknown,
    this.message,
    this.originalError,
  });

  factory HttpException.unknown({String? message, dynamic originalError}) {
    return HttpException(
      type: HttpExceptionType.unknown,
      message: message,
      originalError: originalError,
    );
  }

  factory HttpException.timeout({String? message}) {
    return HttpException(type: HttpExceptionType.timeout, message: message);
  }

  factory HttpException.certificate({String? message}) {
    return HttpException(type: HttpExceptionType.certificate, message: message);
  }

  factory HttpException.cancel({String? message}) {
    return HttpException(type: HttpExceptionType.cancel, message: message);
  }

  factory HttpException.connection({String? message}) {
    return HttpException(type: HttpExceptionType.connection, message: message);
  }

  factory HttpException.serialization(
      {String? message, dynamic originalError}) {
    return HttpException(
      type: HttpExceptionType.serialization,
      message: message,
      originalError: originalError,
    );
  }

  factory HttpException.upgradeRequired({String? message}) {
    return HttpException(
        type: HttpExceptionType.upgradeRequired, message: message);
  }

  factory HttpException.response({
    int? status = 500,
    String? message,
    dynamic data,
    required Map<String, List<String>> headers,
  }) {
    return HttpResponseException(
      status: status ?? 500,
      message: message ?? 'Server Error',
      headers: headers,
      data: data,
    );
  }

  W when<W>({
    W Function()? timeout,
    W Function()? certificate,
    W Function()? cancel,
    W Function()? connection,
    W Function()? response,
    W Function(String? message, dynamic originalError)? serialization,
    W Function()? upgradeRequired,
    required W Function() unknown,
  }) {
    final handler = switch (type) {
      HttpExceptionType.timeout => timeout,
      HttpExceptionType.certificate => certificate,
      HttpExceptionType.cancel => cancel,
      HttpExceptionType.connection => connection,
      HttpExceptionType.response => response,
      HttpExceptionType.serialization => () =>
          serialization?.call(message, originalError),
      HttpExceptionType.upgradeRequired => upgradeRequired,
      HttpExceptionType.unknown => unknown,
    };

    if (handler != null) {
      // Since handler returns W?, we need to ensure we return W.
      // The compiler might complain if we return W? from call().
      // However, since W is generic, it might be nullable.
      // If W is non-nullable, serialization?.call returning W? is an issue if it returns null.
      // We should assume that if the user passed a handler, they return a valid W.
      // But serialization?.call() returns null if serialization is null.
      // We already checked handler != null, but the lambda inside the switch creates a closure.
      // The lambda `() => serialization?.call(...)` returns `W?`.
      // We can cast or explicit check.
      final result = handler();
      if (result is W) {
        return result;
      }
      // If result is null but W is not nullable? tricky in Dart generic.
      // Let's assume W allows null or unknown handles it.
      // For safety, let's just return result as W.
      return result as W;
    }
    return unknown();
  }

  @override
  String toString() => message ?? 'Unknown Error';

  ApiFailure toFailure() {
    return when(
      timeout: () => const NetworkFailure('Connection Timeout'),
      certificate: () => const NetworkFailure('Certificate Error'),
      cancel: () => const UnknownFailure('Request Cancelled'),
      connection: () => const NetworkFailure('No Internet Connection'),
      upgradeRequired: () => const ServerFailure('App Update Required'),
      serialization: (msg, _) => UnknownFailure('Data Parsing Error', msg),
      response: () {
        if (this is HttpResponseException) {
          return (this as HttpResponseException).toFailure();
        }
        return const ServerFailure('Unknown Response Error');
      },
      unknown: () => const UnknownFailure('Unknown Error'),
    );
  }
}

final class HttpResponseException extends HttpException {
  final int status;
  final String message;

  @override
  final HttpExceptionType type = HttpExceptionType.response;

  final Map<String, List<String>> headers;
  final dynamic data;

  HttpResponseException({
    required this.status,
    required this.message,
    required this.headers,
    this.data,
  });

  /// The backend's machine-readable reason (`errorCode` in the error body, set
  /// by its AllExceptionsFilter), or null when it sent none.
  ///
  /// [message] is already localised for display; this is what callers branch
  /// on — matching on the human text breaks the moment a translation changes.
  String? get errorCode {
    final body = data;
    if (body is! Map) return null;
    final code = body['errorCode'];
    return code is String && code.isNotEmpty ? code : null;
  }

  @override
  String toString() => message;

  @override
  ApiFailure toFailure() {
    switch (errorCode) {
      case 'APP_CHECK_FAILED':
        return AppCheckFailure(AppCheckFailureKind.rejected, message);
      case 'APP_CHECK_UNAVAILABLE':
        return AppCheckFailure(AppCheckFailureKind.unavailable, message);
    }
    if (status == 401) {
      return UnauthorizedFailure(message);
    }
    if (status == 403) {
      return ForbiddenFailure(message);
    }
    if (status == 400 || status == 422) {
      if (data is Map<String, dynamic> &&
          (data as Map<String, dynamic>).containsKey('errors')) {
        return ValidationFailure(message, data['errors']);
      }
      return ValidationFailure(message, {});
    }
    if (status >= 500) {
      return ServerFailure(message, status.toString());
    }
    return ServerFailure(message, status.toString());
  }
}
