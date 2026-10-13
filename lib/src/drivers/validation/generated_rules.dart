// GENERATED CODE - DO NOT MODIFY BY HAND
// Last updated: 2026-01-22 22:05:04.362892

class ValidationConstants {
  /// Localized rules for [en]
  static const Map<String, dynamic> rules_en = {
    "auth": {
      "password": {
        "type": "string",
        "minLength": 8,
        "maxLength": 32,
        "pattern": "[0-9]",
        "description": "Password must contain at least one digit",
        "errorMessages": {
          "minLength": "Password must be at least 8 characters",
          "maxLength": "Password must not exceed 32 characters",
          "pattern": "Password must contain at least one digit"
        }
      },
      "email": {
        "type": "string",
        "format": "email",
        "description": "Invalid email format"
      }
    }
  };

  /// Localized rules for [uk]
  static const Map<String, dynamic> rules_uk = {
    "auth": {
      "password": {
        "type": "string",
        "minLength": 8,
        "maxLength": 32,
        "pattern": "[0-9]",
        "description": "Пароль повинен містити принаймні одну цифру",
        "errorMessages": {
          "minLength": "Пароль має бути не менше 8 символів",
          "maxLength": "Пароль не повинен перевищувати 32 символи",
          "pattern": "Пароль повинен містити принаймні одну цифру"
        }
      },
      "email": {
        "type": "string",
        "format": "email",
        "description": "Невірний формат email"
      }
    }
  };

  /// Helper to get rules for current language
  static Map<String, dynamic> getRules(String languageCode) {
    return switch (languageCode) {
      'uk' => rules_uk,
      _ => rules_en,
    };
  }
}
