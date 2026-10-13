import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shared_api/shared_api.dart';

/// A production-grade Interceptor for HTTP caching.
///
/// Features:
/// - Per-request control via [HttpCachePolicy] (opt-in, `noCache` by default).
/// - RFC 7232 conditional GET (ETag / Last-Modified) for expired entries.
/// - Stale-while-revalidate: serve expired data now, refresh in background.
/// - Respects "Cache-Control" (max-age, no-store, no-cache) and "Expires".
/// - Gracefully handles storage failures: the network path always works.
/// - Robust key generation considering host, path, sorted queries and the
///   request headers listed in [varyHeaders] (`Accept-Language` by default),
///   or a fully custom [cacheKeyBuilder].
///
/// [ApiClient] installs this interceptor automatically for its [HttpCache].
class CacheInterceptor extends Interceptor {
  final HttpCache cache;
  final Duration defaultTtl;

  /// Request headers the default cache key varies on, so responses that
  /// differ by e.g. tenant, currency or country are cached separately.
  /// Ignored when [cacheKeyBuilder] is set.
  final List<String> varyHeaders;

  /// Builds the cache key for a request, replacing the default key
  /// ([defaultCacheKey]) entirely.
  final String Function(RequestOptions options)? cacheKeyBuilder;

  /// Default [varyHeaders]: the cache varies by language only.
  static const defaultVaryHeaders = [HttpHeaders.acceptLanguageHeader];

  /// Dio used to fire background refreshes for
  /// [HttpCachePolicy.staleWhileRevalidate] and to recover from a `304` whose
  /// entry was evicted mid-flight. Assigned after construction because Dio
  /// owns this interceptor. When null, stale-while-revalidate degrades to
  /// serve-stale-only.
  Dio? dio;

  /// Keys with a background revalidation in flight, so concurrent stale
  /// reads of the same resource trigger a single network request.
  final Set<String> _revalidating = {};

  /// Marks requests whose conditional headers were added by this interceptor.
  static const _conditionalKey = 'shared_api.cache.conditional';

  CacheInterceptor({
    required this.cache,
    this.defaultTtl = const Duration(minutes: 5),
    this.dio,
    this.varyHeaders = defaultVaryHeaders,
    this.cacheKeyBuilder,
  });

  @override
  Future<void> onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    // Only GET requests are cacheable.
    if (options.method != 'GET') return handler.next(options);

    final policy = _cachePolicy(options.extra[HttpConstants.cachePolicyKey]);

    // noCache: bypass entirely. refresh: skip read, store on response.
    if (policy == HttpCachePolicy.noCache ||
        policy == HttpCachePolicy.refresh) {
      return handler.next(options);
    }

    final key = await _resolveKey(options);
    final entry = await _read(key);

    if (entry == null) {
      if (policy == HttpCachePolicy.onlyCache) {
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
            error: 'Cache miss for onlyCache policy',
          ),
        );
      }
      return handler.next(options);
    }

    if (!entry.isExpired) {
      return handler.resolve(_toResponse(entry, options));
    }

    // Expired entry below.
    switch (policy) {
      case HttpCachePolicy.onlyCache:
        return handler.resolve(_toResponse(entry, options));
      case HttpCachePolicy.staleWhileRevalidate:
        unawaited(_revalidate(options, key, entry));
        return handler.resolve(_toResponse(entry, options));
      default:
        // useCache: conditional GET (RFC 7232).
        if (entry.hasValidators) {
          _addValidators(options.headers, entry);
          options.extra[_conditionalKey] = true;
        }
        return handler.next(options);
    }
  }

  @override
  Future<void> onResponse(
      Response response, ResponseInterceptorHandler handler) async {
    final options = response.requestOptions;
    final policy = _cachePolicy(options.extra[HttpConstants.cachePolicyKey]);

    if (options.method != 'GET' || policy == HttpCachePolicy.noCache) {
      return handler.next(response);
    }

    final key = await _resolveKey(options);

    if (response.statusCode == 304) {
      final entry = await _read(key);
      if (entry != null) {
        final directives = _parseDirectives(response.headers);
        await _write(
          key,
          entry.data,
          ttl: directives.ttl ?? defaultTtl,
          eTag: response.headers.value('etag') ?? entry.eTag,
          lastModified:
              response.headers.value('last-modified') ?? entry.lastModified,
          headers: entry.headers,
        );
        return handler.resolve(_toResponse(entry, options, stale: false));
      }

      // The entry was evicted between request and response. Our validators
      // produced this 304, so the caller would get an empty body: re-fetch
      // unconditionally instead.
      final client = dio;
      if (options.extra[_conditionalKey] == true && client != null) {
        try {
          final fresh = await client.fetch<dynamic>(_unconditional(options));
          return handler.resolve(fresh);
        } on DioException catch (e) {
          return handler.reject(e);
        }
      }
      return handler.next(response);
    }

    if (response.statusCode == 200) {
      final directives = _parseDirectives(response.headers);
      final varyNames = _responseVary(response.headers);
      if (directives.noStore || varyNames == null) {
        // no-store, or `Vary: *` (never a cache hit): do not keep anything.
        await _remove(key);
      } else {
        final eTag = response.headers.value('etag');
        final lastModified = response.headers.value('last-modified');
        final ttl = directives.ttl ?? defaultTtl;
        // A zero TTL is still worth storing when it can be revalidated.
        if (ttl > Duration.zero || eTag != null || lastModified != null) {
          // The response may vary on request headers beyond the key's own:
          // remember which ones and store this entry under that variant.
          final base = _getCacheKey(options);
          await _storeVaryIndex(base, varyNames);
          await _write(
            _variantKey(base, varyNames, options),
            response.data,
            ttl: ttl,
            eTag: eTag,
            lastModified: lastModified,
            headers: response.headers.map,
          );
        }
      }
    }

    handler.next(response);
  }

  /// Fires a background network refresh for a stale entry. Re-runs the
  /// request with [HttpCachePolicy.refresh] so the cache read is skipped and
  /// [onResponse] stores the result (`304` extends the entry, `200` replaces
  /// it). Errors are swallowed: the caller already received the stale data.
  Future<void> _revalidate(
      RequestOptions options, String key, CacheEntry entry) async {
    final client = dio;
    if (client == null || !_revalidating.add(key)) return;
    try {
      final headers = {...options.headers};
      _addValidators(headers, entry);
      await client.fetch<dynamic>(
        options.copyWith(
          headers: headers,
          // Detach from the caller: cancelling the original request (e.g. a
          // disposed screen) must not cancel the cache refresh.
          cancelToken: CancelToken(),
          extra: {
            ...options.extra,
            HttpConstants.cachePolicyKey: HttpCachePolicy.refresh,
          },
        ),
      );
    } catch (_) {
      // Best-effort: stale data stands until the next successful refresh.
    } finally {
      _revalidating.remove(key);
    }
  }

  void _addValidators(Map<String, dynamic> headers, CacheEntry entry) {
    if (entry.eTag != null) headers['If-None-Match'] = entry.eTag;
    if (entry.lastModified != null) {
      headers['If-Modified-Since'] = entry.lastModified;
    }
  }

  RequestOptions _unconditional(RequestOptions options) {
    final headers = {...options.headers}
      ..remove('If-None-Match')
      ..remove('If-Modified-Since');
    final extra = {...options.extra}..remove(_conditionalKey);
    return options.copyWith(headers: headers, extra: extra);
  }

  Future<CacheEntry?> _read(String key) async {
    try {
      return await cache.get(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(
    String key,
    dynamic data, {
    required Duration ttl,
    String? eTag,
    String? lastModified,
    Map<String, List<String>> headers = const {},
  }) async {
    try {
      await cache.set(
        key,
        data,
        expiresAt: DateTime.now().add(ttl.isNegative ? Duration.zero : ttl),
        eTag: eTag,
        lastModified: lastModified,
        headers: headers,
      );
    } catch (_) {}
  }

  Future<void> _remove(String key) async {
    try {
      await cache.remove(key);
    } catch (_) {}
  }

  /// Storage key of the vary index for [base]: which request headers the
  /// cached responses vary on (from the response `Vary` header).
  static String _varyIndexKey(String base) => '$base#vary';

  /// Key of the cached variant for [options]: [_getCacheKey] plus the values
  /// of the request headers the server said the response varies on.
  Future<String> _resolveKey(RequestOptions options) async {
    final base = _getCacheKey(options);
    final index = await _read(_varyIndexKey(base));
    final data = index?.data;
    final names = data is List ? data.whereType<String>().toList() : <String>[];
    return _variantKey(base, names, options);
  }

  static String _variantKey(
      String base, List<String> names, RequestOptions options) {
    if (names.isEmpty) return base;
    final values = names.map((n) => '&vary:$n=${options.headers[n] ?? ''}');
    return '$base${values.join()}';
  }

  Future<void> _storeVaryIndex(String base, List<String> names) async {
    if (names.isEmpty) return _remove(_varyIndexKey(base));
    await _write(
      _varyIndexKey(base),
      names,
      ttl: const Duration(days: 365),
    );
  }

  /// Request header names the response varies on, lower-cased and without the
  /// ones the cache key already includes. Null means `Vary: *`: the response
  /// can never be served from cache.
  List<String>? _responseVary(Headers headers) {
    final values = headers[HttpHeaders.varyHeader];
    if (values == null) return const [];
    final names = values
        .expand((v) => v.split(','))
        .map((n) => n.trim().toLowerCase())
        .where((n) => n.isNotEmpty)
        .toSet();
    if (names.contains('*')) return null;
    final inKey = cacheKeyBuilder == null
        ? varyHeaders.map((h) => h.toLowerCase()).toSet()
        : const <String>{};
    return (names.difference(inKey).toList()..sort());
  }

  String _getCacheKey(RequestOptions options) =>
      cacheKeyBuilder?.call(options) ??
      defaultCacheKey(options, varyHeaders: varyHeaders);

  /// Default cache key: base URL, path, query parameters sorted
  /// alphabetically (to avoid redundant entries for the same conceptual
  /// request) and the value of each of [varyHeaders].
  ///
  /// `Accept-Language` is labelled `lang` so keys stay compatible with
  /// entries stored by earlier versions.
  static String defaultCacheKey(
    RequestOptions options, {
    List<String> varyHeaders = defaultVaryHeaders,
  }) {
    final query = Map.from(options.queryParameters);
    final sortedKeys = query.keys.map((k) => k.toString()).toList()..sort();
    final queryString = sortedKeys.map((k) => '$k=${query[k]}').join('&');

    final vary = varyHeaders.map((header) {
      final name = header.toLowerCase();
      final label = name == HttpHeaders.acceptLanguageHeader ? 'lang' : name;
      return '&$label=${options.headers[header] ?? ''}';
    }).join();

    return '${options.baseUrl}${options.path}?$queryString$vary';
  }

  /// Parses "Cache-Control" and "Expires" into a TTL and store permission.
  ///
  /// `no-store` forbids storing; `no-cache` stores but always revalidates
  /// (zero TTL). Malformed headers fall back to [defaultTtl].
  ({Duration? ttl, bool noStore}) _parseDirectives(Headers headers) {
    final cacheControl = headers.value('cache-control')?.toLowerCase();
    if (cacheControl != null) {
      if (cacheControl.contains('no-store')) {
        return (ttl: Duration.zero, noStore: true);
      }
      if (cacheControl.contains('no-cache')) {
        return (ttl: Duration.zero, noStore: false);
      }
      final match = RegExp(r'max-age=(\d+)').firstMatch(cacheControl);
      final seconds = match == null ? null : int.tryParse(match.group(1)!);
      if (seconds != null) {
        return (ttl: Duration(seconds: seconds), noStore: false);
      }
    }

    final expires = headers.value('expires');
    if (expires != null) {
      try {
        final ttl = HttpDate.parse(expires).difference(DateTime.now());
        return (ttl: ttl.isNegative ? Duration.zero : ttl, noStore: false);
      } catch (_) {
        // Malformed (e.g. "Expires: 0") means already expired.
        return (ttl: Duration.zero, noStore: false);
      }
    }

    return (ttl: null, noStore: false);
  }

  Response _toResponse(CacheEntry entry, RequestOptions options,
      {bool? stale}) {
    return Response(
      requestOptions: options,
      data: entry.data,
      statusCode: 200,
      statusMessage: 'OK (From Cache)',
      // Build a new map: never mutate the cached entry's headers in place.
      headers: Headers.fromMap({
        ...entry.headers,
        'x-from-cache': ['true'],
        if (stale ?? entry.isExpired) 'x-cache-stale': ['true'],
      }),
    );
  }

  // noCache when absent: caching is opt-in per request.
  static HttpCachePolicy _cachePolicy(dynamic raw) {
    return raw is HttpCachePolicy ? raw : HttpCachePolicy.noCache;
  }
}
