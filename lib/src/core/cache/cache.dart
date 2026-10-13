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
  ///
  /// An expired entry is still usable: it can be served stale
  /// ([HttpCachePolicy.staleWhileRevalidate]) or revalidated with a
  /// conditional GET using [eTag] / [lastModified].
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Whether the entry has been expired for longer than [maxStale] and
  /// should be evicted instead of served or revalidated.
  bool isStaleBeyond(Duration maxStale) =>
      DateTime.now().isAfter(expiresAt.add(maxStale));

  /// Whether the entry carries a validator usable for a conditional GET.
  bool get hasValidators => eTag != null || lastModified != null;

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
  factory CacheEntry.fromJson(Map<String, dynamic> json) {
    // Tolerant parsing: a corrupt entry is treated as expired, never thrown.
    final expiresRaw = json['expiresAt'];
    final createdRaw = json['createdAt'];
    final headersRaw = json['headers'];
    final eTagRaw = json['eTag'];
    final lastModifiedRaw = json['lastModified'];

    return CacheEntry(
      data: json['data'],
      expiresAt:
          (expiresRaw is String ? DateTime.tryParse(expiresRaw) : null) ??
              DateTime.now(),
      createdAt:
          (createdRaw is String ? DateTime.tryParse(createdRaw) : null) ??
              DateTime.now(),
      headers: headersRaw is Map
          ? headersRaw.map(
              (k, v) => MapEntry(
                k.toString(),
                v is List ? v.map((e) => e.toString()).toList() : <String>[],
              ),
            )
          : const {},
      eTag: eTagRaw is String ? eTagRaw : null,
      lastModified: lastModifiedRaw is String ? lastModifiedRaw : null,
    );
  }
}

/// Interface for HTTP response caching implementations.
/// Allows for pluggable storage backends (e.g., In-Memory, Hive, SQFLite).
///
/// Contract:
/// - [get] returns an entry **even when it is expired**. Freshness is decided
///   by the caller (`CacheInterceptor`): expired entries are revalidated with
///   a conditional GET or served stale, depending on the request policy.
/// - Implementations own eviction (capacity and/or age) and must never let a
///   storage failure escape: return `null` / no-op instead.
abstract class HttpCache {
  /// Retrieves a [CacheEntry] for the given [key], fresh or expired.
  /// Returns `null` if no entry is found or if retrieval fails.
  Future<CacheEntry?> get(String key);

  /// Stores [value] in the cache under [key], replacing any existing entry.
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
  ///
  /// Called on sign-out / account switch so one user's responses are never
  /// served to another.
  Future<void> clear();
}

/// In-memory [HttpCache] with LRU capacity management and age-based eviction.
///
/// Expired entries are kept for [maxStale] after expiry so they can be served
/// stale or revalidated cheaply (`304 Not Modified`). After that they are
/// evicted on access. When [maxEntries] is reached, the least recently used
/// entry is evicted.
class MapHttpCache implements HttpCache {
  // LinkedHashMap keeps insertion order; re-inserting on access makes the
  // first key the least recently used one.
  final Map<String, CacheEntry> _storage = {};

  /// The maximum number of entries to keep in memory.
  final int maxEntries;

  /// How long an entry is kept after it expires.
  final Duration maxStale;

  MapHttpCache({
    this.maxEntries = 100,
    this.maxStale = const Duration(days: 1),
  }) : assert(maxEntries > 0, 'maxEntries must be positive');

  /// Number of entries currently stored.
  int get length => _storage.length;

  @override
  Future<CacheEntry?> get(String key) async {
    try {
      final entry = _storage.remove(key);
      if (entry == null) return null;

      if (entry.isStaleBeyond(maxStale)) return null;

      // Mark as most recently used.
      _storage[key] = entry;
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
      // Replacing an existing key must not evict an unrelated entry.
      _storage.remove(key);
      while (_storage.length >= maxEntries) {
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
