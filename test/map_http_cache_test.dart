import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/core/cache/cache.dart';

void main() {
  group('MapHttpCache', () {
    test('returns expired entries within maxStale', () async {
      final cache = MapHttpCache();
      await cache.set('k', 'v',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)));

      final entry = await cache.get('k');
      expect(entry, isNotNull);
      expect(entry!.isExpired, isTrue);
      expect(entry.data, 'v');
    });

    test('evicts entries expired longer than maxStale', () async {
      final cache = MapHttpCache(maxStale: const Duration(minutes: 1));
      await cache.set('k', 'v',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 2)));

      expect(await cache.get('k'), isNull);
      expect(cache.length, 0);
    });

    test('evicts least recently used entry at capacity', () async {
      final cache = MapHttpCache(maxEntries: 2);
      final expiresAt = DateTime.now().add(const Duration(minutes: 5));
      await cache.set('a', 1, expiresAt: expiresAt);
      await cache.set('b', 2, expiresAt: expiresAt);

      // Touch "a" so "b" becomes least recently used.
      await cache.get('a');
      await cache.set('c', 3, expiresAt: expiresAt);

      expect(await cache.get('a'), isNotNull);
      expect(await cache.get('b'), isNull);
      expect(await cache.get('c'), isNotNull);
    });

    test('replacing an existing key does not evict another entry', () async {
      final cache = MapHttpCache(maxEntries: 2);
      final expiresAt = DateTime.now().add(const Duration(minutes: 5));
      await cache.set('a', 1, expiresAt: expiresAt);
      await cache.set('b', 2, expiresAt: expiresAt);
      await cache.set('b', 3, expiresAt: expiresAt);

      expect(cache.length, 2);
      expect((await cache.get('a'))?.data, 1);
      expect((await cache.get('b'))?.data, 3);
    });
  });

  group('CacheEntry.fromJson', () {
    test('tolerates corrupt fields', () {
      final entry = CacheEntry.fromJson({
        'data': 'x',
        'expiresAt': 42,
        'createdAt': 'not a date',
        'headers': 'broken',
        'eTag': 1,
      });

      expect(entry.data, 'x');
      expect(entry.headers, isEmpty);
      expect(entry.eTag, isNull);
      expect(entry.hasValidators, isFalse);
    });
  });
}
