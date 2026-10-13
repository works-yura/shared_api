import 'dart:convert';

class JsonDeserializationException implements Exception {
  final String key;
  final dynamic value;
  final Type expectedType;
  final String message;

  JsonDeserializationException(this.key, this.value, this.expectedType,
      [this.message = '']);

  @override
  String toString() =>
      'JsonDeserializationException: Key "$key" expected $expectedType, but got ${value.runtimeType} ($value). $message';
}

class JsonObject {
  final Map<String, dynamic> _data;

  const JsonObject(this._data);

  /// Factory to create from string safely
  factory JsonObject.fromString(String source) {
    try {
      final dynamic decoded = json.decode(source);
      return JsonObject(decoded is Map<String, dynamic> ? decoded : {});
    } catch (_) {
      return const JsonObject({});
    }
  }

  /// Returns value of type [T] or [defaultValue].
  /// Supports type casting for numeric values.
  T as<T>(String key, T defaultValue) {
    final value = _data[key];
    if (value == null) return defaultValue;
    if (value is T) return value;

    final coerced = _coerce<T>(value, toText: true);
    if (coerced is T) return coerced;

    return defaultValue;
  }

  /// Returns value or throws exception if field is missing or invalid type.
  T required<T>(String key) {
    final value = _data[key];
    if (value == null) {
      throw JsonDeserializationException(key, null, T, 'Field is mandatory');
    }

    if (value is T) return value;

    final coerced = _coerce<T>(value, toText: false);
    if (coerced is T) return coerced;

    throw JsonDeserializationException(key, value, T);
  }

  /// Converts [value] to [T] (nullable or not) where a lossless-enough
  /// conversion exists: num -> double / int and, if [toText], any -> String.
  /// Returns null when no conversion applies.
  static Object? _coerce<T>(Object value, {required bool toText}) {
    if (value is num) {
      final asDouble = value.toDouble();
      if (asDouble is T) return asDouble;
      final asInt = value.toInt();
      if (asInt is T) return asInt;
    }
    if (toText) {
      final text = value.toString();
      if (text is T) return text;
    }
    return null;
  }

  /// Maps a nested object to type [R] if it exists.
  R? map<R>(String key, R Function(Map<String, dynamic> json) mapper) {
    final value = _data[key];
    if (value is Map<String, dynamic>) return mapper(value);
    return null;
  }

  /// Unified method for deserializing lists of objects.
  List<R> listAs<R>(String key, R Function(Map<String, dynamic> json) mapper) {
    final value = _data[key];
    if (value is! List) return const [];
    return value.whereType<Map<String, dynamic>>().map(mapper).toList();
  }

  /// Safe DateTime parsing
  DateTime time(String key, {DateTime? orElse}) {
    final value = _data[key];
    if (value == null) return orElse ?? DateTime.now();
    return DateTime.tryParse(value.toString()) ?? (orElse ?? DateTime.now());
  }

  /// Nullable DateTime parsing. Returns null when the field is
  /// missing, empty or unparseable.
  DateTime? timeOrNull(String key) {
    final value = _data[key];
    if (value == null) return null;
    final raw = value.toString();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Get nested object
  JsonObject object(String key) {
    final value = _data[key];
    return JsonObject(value is Map<String, dynamic> ? value : {});
  }

  /// Get list of objects with mapping
  List<R> list<R>(String key, R Function(JsonObject json) mapper) {
    final value = _data[key];
    if (value is! List) return [];

    return value
        .whereType<Map<String, dynamic>>()
        .map((e) => mapper(JsonObject(e)))
        .toList();
  }

  /// Get list of primitives
  List<T> primitives<T>(String key) {
    final value = _data[key];
    if (value is! List) return [];
    return value.whereType<T>().toList();
  }

  Map<String, dynamic> toMap() => Map.unmodifiable(_data);

  bool containsKey(String key) => _data.containsKey(key);

  bool get isEmpty => _data.isEmpty;

  bool get isNotEmpty => _data.isNotEmpty;
}

extension MapToJsonObject on Map<String, dynamic> {
  JsonObject get json => JsonObject(this);
}
