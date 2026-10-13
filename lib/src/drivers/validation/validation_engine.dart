/// Validation engine that interprets localized JSON Schema rules from the backend.
class ValidationEngine {
  /// Localized error messages for fallback
  static const _fallbacks = {
    'en': {
      'fieldRequired': 'Field is required',
      'invalidFormat': 'Invalid format',
    },
    'uk': {
      'fieldRequired': 'Поле обов’язкове',
      'invalidFormat': 'Невірний формат',
    }
  };

  /// Validates a [value] against a [schema] Map with localization support.
  /// [languageCode] is used to resolve fallback messages.
  static String? validate(String? value, Map<String, dynamic> schema,
      {String languageCode = 'en'}) {
    final t = _fallbacks[languageCode] ?? _fallbacks['en']!;
    final errorMessages = schema['errorMessages'] as Map<String, dynamic>?;

    if (value == null || value.isEmpty) {
      return errorMessages?['required'] ?? t['fieldRequired'];
    }

    // 1. Min Length
    if (schema.containsKey('minLength')) {
      final min = schema['minLength'] as int;
      if (value.length < min) {
        return errorMessages?['minLength'] ??
            schema['description'] ??
            'Too short';
      }
    }

    // 2. Max Length
    if (schema.containsKey('maxLength')) {
      final max = schema['maxLength'] as int;
      if (value.length > max) {
        return errorMessages?['maxLength'] ??
            schema['description'] ??
            'Too long';
      }
    }

    // 3. Pattern (Regex)
    if (schema.containsKey('pattern')) {
      final pattern = schema['pattern'] as String;
      final regex = RegExp(pattern);
      if (!regex.hasMatch(value)) {
        return errorMessages?['pattern'] ??
            schema['description'] ??
            t['invalidFormat'];
      }
    }

    return null;
  }
}
