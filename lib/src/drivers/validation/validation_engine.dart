/// Validation engine that interprets localized JSON Schema rules from the backend.
///
/// Supported keywords: `minLength`, `maxLength`, `pattern`. Per-rule messages
/// come from the schema's `errorMessages` / `description`; otherwise from
/// [messages] (keys: `fieldRequired`, `tooShort`, `tooLong`, `invalidFormat`),
/// falling back to English.
class ValidationEngine {
  /// Default English fallback messages.
  static const defaultMessages = {
    'fieldRequired': 'Field is required',
    'tooShort': 'Too short',
    'tooLong': 'Too long',
    'invalidFormat': 'Invalid format',
  };

  /// Validates a [value] against a [schema] Map.
  /// [messages] overrides fallback messages (e.g. localized strings).
  static String? validate(
    String? value,
    Map<String, dynamic> schema, {
    Map<String, String>? messages,
  }) {
    String fallback(String key) =>
        messages?[key] ?? defaultMessages[key] ?? '';

    final rawMessages = schema['errorMessages'];
    final errorMessages = rawMessages is Map ? rawMessages : const {};
    String? schemaMessage(String key) {
      final custom = errorMessages[key];
      if (custom is String) return custom;
      final description = schema['description'];
      return description is String ? description : null;
    }

    if (value == null || value.isEmpty) {
      final required = errorMessages['required'];
      return required is String ? required : fallback('fieldRequired');
    }

    // 1. Min Length
    final min = schema['minLength'];
    if (min is int && value.length < min) {
      return schemaMessage('minLength') ?? fallback('tooShort');
    }

    // 2. Max Length
    final max = schema['maxLength'];
    if (max is int && value.length > max) {
      return schemaMessage('maxLength') ?? fallback('tooLong');
    }

    // 3. Pattern (Regex)
    final pattern = schema['pattern'];
    if (pattern is String && !RegExp(pattern).hasMatch(value)) {
      return schemaMessage('pattern') ?? fallback('invalidFormat');
    }

    return null;
  }
}
