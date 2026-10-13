/// Helper class for API validation logic.
class HttpValidator {
  /// Validates the HTTP status code.
  ///
  /// Returns `true` if the status code indicates a success (200-299)
  /// or a cached response (304).
  static bool validateStatus(int? status) {
    if (status == null) return false;
    return (status >= 200 && status < 300) || status == 304;
  }
}
