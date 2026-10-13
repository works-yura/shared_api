/// Represents a cached HTTP response entry with metadata according to RFC 7234.
class CacheEntry {
  /// The cached response body.
  final dynamic data;

  /// The exact time when this entry expires.
  final DateTime expiresAt;

  /// The time when this entry was created or last validated.
  final DateTime createdAt;

  /// HTTP ETag (entity tag) for validation.
  final String? eTag;

  /// HTTP Last-Modified header for validation.
  final String? lastModified;

  /// Additional headers that might be relevant (e.g., Content-Type).
  final Map<String, List<String>> headers;

  CacheEntry({
    required this.data,
    required this.expiresAt,
    required this.createdAt,
    required this.headers,
    this.eTag,
    this.lastModified,
  });

  /// Whether the entry is considered expired based on current time.
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Converts the entry to a JSON-compatible map for persistence.
  Map<String, dynamic> toJson() => {
        'data': data,
        'expiresAt': expiresAt.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'eTag': eTag,
        'lastModified': lastModified,
        'headers': headers,
      };

  /// Creates an entry from a JSON-compatible map.
  factory CacheEntry.fromJson(Map<String, dynamic> json) => CacheEntry(
        data: json['data'],
        expiresAt: DateTime.parse(json['expiresAt']),
        createdAt: DateTime.parse(json['createdAt']),
        headers: (json['headers'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, List<String>.from(v as List)),
        ),
        eTag: json['eTag'] as String?,
        lastModified: json['lastModified'] as String?,
      );
}

/// Interface for HTTP response caching implementations.
/// Allows for pluggable storage backends (e.g., In-Memory, Hive, SQFLite).
abstract class HttpCache {
  /// Retrieves a [CacheEntry] for the given [key].
  /// Returns `null` if no entry is found or if retrieval fails.
  Future<CacheEntry?> get(String key);

  /// Stores [value] in the cache under [key].
  Future<void> set(
    String key,
    dynamic value, {
    required DateTime expiresAt,
    String? eTag,
    String? lastModified,
    Map<String, List<String>> headers = const {},
  });

  /// Removes the entry for [key] from the cache.
  Future<void> remove(String key);

  /// Clears all entries from the cache.
  Future<void> clear();
}

/// A production-ready in-memory implementation of [HttpCache] with capacity management.
class MapHttpCache implements HttpCache {
  final Map<String, CacheEntry> _storage = {};

  /// The maximum number of entries to keep in memory.
  final int maxEntries;

  MapHttpCache({this.maxEntries = 100});

  @override
  Future<CacheEntry?> get(String key) async {
    try {
      final entry = _storage[key];
      if (entry == null) return null;

      // Auto-cleanup expired entries on access to keep memory clean
      if (entry.isExpired) {
        _storage.remove(key);
        return null;
      }

      return entry;
    } catch (_) {
      return null; // Graceful failure for production
    }
  }

  @override
  Future<void> set(
    String key,
    dynamic value, {
    required DateTime expiresAt,
    String? eTag,
    String? lastModified,
    Map<String, List<String>> headers = const {},
  }) async {
    try {
      if (_storage.length >= maxEntries) {
        // Simple eviction: remove oldest entry (first key in LinkedHashMap)
        _storage.remove(_storage.keys.first);
      }

      _storage[key] = CacheEntry(
        data: value,
        expiresAt: expiresAt,
        createdAt: DateTime.now(),
        headers: headers,
        eTag: eTag,
        lastModified: lastModified,
      );
    } catch (_) {
      // Production code should not crash because of cache storage failure
    }
  }

  @override
  Future<void> remove(String key) async {
    _storage.remove(key);
  }

  @override
  Future<void> clear() async {
    _storage.clear();
  }
}
