import 'package:shared_api/src/core/exceptions/error_envelope.dart';
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
    ErrorEnvelopeParser envelope = const ErrorEnvelopeParser(),
  }) {
    return HttpResponseException(
      status: status ?? 500,
      message: message ?? 'Server Error',
      headers: headers,
      data: data,
      envelope: envelope,
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
      HttpExceptionType.serialization => serialization == null
          ? null
          : () => serialization(message, originalError),
      HttpExceptionType.upgradeRequired => upgradeRequired,
      HttpExceptionType.unknown => unknown,
    };

    return (handler ?? unknown)();
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

  /// Reads [errorCode] and validation errors from [data], and maps known codes
  /// to failures in [toFailure].
  final ErrorEnvelopeParser envelope;

  HttpResponseException({
    required this.status,
    required this.message,
    required this.headers,
    this.data,
    this.envelope = const ErrorEnvelopeParser(),
  });

  /// The backend's machine-readable reason (per [envelope]; `errorCode` in the
  /// error body by default), or null when it sent none.
  ///
  /// [message] is usually localised for display; this is what callers branch
  /// on — matching on the human text breaks the moment a translation changes.
  String? get errorCode => envelope.code(data);

  @override
  String toString() => message;

  @override
  ApiFailure toFailure() {
    final byCode = envelope.codeFailures[errorCode];
    if (byCode != null) return byCode(this);
    if (status == 401) {
      return UnauthorizedFailure(message);
    }
    if (status == 403) {
      return ForbiddenFailure(message);
    }
    if (status == 400 || status == 422) {
      return ValidationFailure(message, envelope.fieldErrors(data) ?? {});
    }
    if (status >= 500) {
      return ServerFailure(message, status.toString());
    }
    return ServerFailure(message, status.toString());
  }
}
