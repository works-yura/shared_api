import 'package:shared_api/src/core/exceptions/exception.dart';
import 'package:shared_api/src/core/exceptions/failures.dart';

/// Builds a domain failure for a response error with a known error code.
typedef ErrorCodeFailure = ApiFailure Function(HttpResponseException error);

/// Failures for the App Check error codes, used by default by
/// [ErrorEnvelopeParser.codeFailures].
const Map<String, ErrorCodeFailure> appCheckCodeFailures = {
  'APP_CHECK_FAILED': _appCheckRejected,
  'APP_CHECK_UNAVAILABLE': _appCheckUnavailable,
};

ApiFailure _appCheckRejected(HttpResponseException e) =>
    AppCheckFailure(AppCheckFailureKind.rejected, e.message);

ApiFailure _appCheckUnavailable(HttpResponseException e) =>
    AppCheckFailure(AppCheckFailureKind.unavailable, e.message);

/// Reads the backend's error body (the "envelope").
///
/// The default expects `{message, errorCode, errors}`, where `message` is a
/// String or a List of Strings. Extend it and override [message], [code] or
/// [fieldErrors] for another backend's shape, and pass it to `ApiClient`.
class ErrorEnvelopeParser {
  /// Failures by [code], checked by [HttpResponseException.toFailure] before
  /// the status-based mapping.
  final Map<String, ErrorCodeFailure> codeFailures;

  const ErrorEnvelopeParser({this.codeFailures = appCheckCodeFailures});

  /// Display message, or null to fall back to the transport's message.
  String? message(Object? data) {
    if (data is! Map) return null;
    final msg = data['message'];
    if (msg is String && msg.isNotEmpty) return msg;
    if (msg is List && msg.isNotEmpty) return msg.join('\n');
    return null;
  }

  /// Machine-readable reason, or null when the server sent none.
  String? code(Object? data) {
    if (data is! Map) return null;
    final code = data['errorCode'];
    return code is String && code.isNotEmpty ? code : null;
  }

  /// Per-field validation errors, or null when the body has none.
  Map<String, dynamic>? fieldErrors(Object? data) {
    if (data is! Map) return null;
    final errors = data['errors'];
    return errors is Map<String, dynamic> ? errors : null;
  }
}
