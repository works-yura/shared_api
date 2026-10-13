abstract class ApiFailure implements Exception {
  final String message;
  final String? code;

  const ApiFailure(this.message, [this.code]);

  @override
  String toString() => 'ApiFailure(message: $message, code: $code)';
}

class ServerFailure extends ApiFailure {
  const ServerFailure(super.message, [super.code]);
}

class NetworkFailure extends ApiFailure {
  const NetworkFailure(super.message, [super.code]);
}

class ValidationFailure extends ApiFailure {
  final Map<String, dynamic> errors;

  const ValidationFailure(super.message, this.errors, [super.code]);

  @override
  String toString() => 'ValidationFailure(message: $message, errors: $errors)';
}

class UnauthorizedFailure extends ApiFailure {
  const UnauthorizedFailure(super.message, [super.code]);
}

class ForbiddenFailure extends ApiFailure {
  const ForbiddenFailure(super.message, [super.code]);
}

enum AppCheckFailureKind { rejected, unavailable }

/// A server App Check verdict, identified by its stable errorCode.
class AppCheckFailure extends ApiFailure {
  final AppCheckFailureKind kind;

  const AppCheckFailure(this.kind, String message) : super(message);
}

class UnknownFailure extends ApiFailure {
  final dynamic originalError;
  const UnknownFailure(super.message, [this.originalError]);
}
