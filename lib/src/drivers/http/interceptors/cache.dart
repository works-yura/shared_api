import 'dart:io';
import 'package:dio/dio.dart';
import 'package:shared_api/shared_api.dart';

/// A production-grade Interceptor for HTTP caching.
///
/// Features:
/// - Supports [HttpCachePolicy] for per-request control.
/// - Implements RFC 7234 basic validation (ETag/Last-Modified).
/// - Respects "Cache-Control" headers (max-age).
/// - Gracefully handles storage failures.
/// - Robust key generation considering host, path, and sorted queries.
class CacheInterceptor extends Interceptor {
  final HttpCache cache;
  final Duration defaultTtl;

  CacheInterceptor({
    required this.cache,
    this.defaultTtl = const Duration(minutes: 5),
  });

  @override
  void onRequest(
      RequestOptions options, RequestInterceptorHandler handler) async {
    // Only cache GET requests unless specified otherwise
    if (options.method != 'GET') return handler.next(options);

    final policy = _cachePolicy(options.extra[HttpConstants.cachePolicyKey]);

    // Skip cache if policy is noCache or refresh
    if (policy == HttpCachePolicy.noCache ||
        policy == HttpCachePolicy.refresh) {
      return handler.next(options);
    }

    try {
      final cacheKey = _getCacheKey(options);
      final entry = await cache.get(cacheKey);

      if (entry != null) {
        if (!entry.isExpired) {
          // Fresh data - resolve immediately
          return handler.resolve(_toResponse(entry, options));
        } else if (policy != HttpCachePolicy.onlyCache) {
          // Stale data - add validation headers for conditional GET (RFC 7232)
          if (entry.eTag != null) {
            options.headers['If-None-Match'] = entry.eTag;
          }
          if (entry.lastModified != null) {
            options.headers['If-Modified-Since'] = entry.lastModified;
          }
        } else {
          // onlyCache policy but entry expired - technically a miss/failure
          // but for simplicity, we resolve with stale if onlyCache is used
          return handler.resolve(_toResponse(entry, options));
        }
      } else if (policy == HttpCachePolicy.onlyCache) {
        // missing in cache and onlyCache policy
        return handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.unknown,
            error: 'Cache miss for onlyCache policy',
          ),
        );
      }
    } catch (_) {
      // Graceful degradation: if cache fails, proceed to network
    }

    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    final options = response.requestOptions;
    final policy = _cachePolicy(options.extra[HttpConstants.cachePolicyKey]);

    if (options.method == 'GET' && policy != HttpCachePolicy.noCache) {
      final cacheKey = _getCacheKey(options);

      // Handle 304 Not Modified
      if (response.statusCode == 304) {
        try {
          final entry = await cache.get(cacheKey);
          if (entry != null) {
            // Update TTL based on new headers
            final ttl = _parseTtl(response.headers) ?? defaultTtl;
            await cache.set(
              cacheKey,
              entry.data,
              expiresAt: DateTime.now().add(ttl),
              eTag: entry.eTag,
              lastModified: entry.lastModified,
              headers: entry.headers,
            );

            // Resolve with cached data but status 200
            return handler.resolve(_toResponse(entry, options));
          }
        } catch (_) {}
      }

      // Handle successful response
      if (response.statusCode == 200) {
        final ttl = _parseTtl(response.headers) ?? defaultTtl;
        if (ttl > Duration.zero) {
          try {
            await cache.set(
              cacheKey,
              response.data,
              expiresAt: DateTime.now().add(ttl),
              eTag: response.headers.value('etag'),
              lastModified: response.headers.value('last-modified'),
              headers: response.headers.map,
            );
          } catch (_) {}
        }
      }
    }
    handler.next(response);
  }

  /// Implementation of robust key generation.
  ///
  /// Includes sanitized path and query parameters sorted alphabetically
  /// to avoid redundant entries for the same conceptual request.
  String _getCacheKey(RequestOptions options) {
    final query = Map.from(options.queryParameters);
    final sortedKeys = query.keys.toList()..sort();
    final queryString = sortedKeys.map((k) => '$k=${query[k]}').join('&');

    // Include Accept-Language in cache key to vary cache by language
    final lang = options.headers[HttpHeaders.acceptLanguageHeader] ?? '';

    return '${options.baseUrl}${options.path}?$queryString&lang=$lang';
  }

  /// Parses Cache-Control max-age or Expires header to determine TTL.
  Duration? _parseTtl(Headers headers) {
    final cacheControl = headers.value('cache-control');
    if (cacheControl != null) {
      final match = RegExp(r'max-age=(\d+)').firstMatch(cacheControl);
      if (match != null) {
        final seconds = int.tryParse(match.group(1)!);
        if (seconds != null) return Duration(seconds: seconds);
      }
      if (cacheControl.contains('no-store') ||
          cacheControl.contains('no-cache')) {
        return Duration.zero;
      }
    }

    final expires = headers.value('expires');
    if (expires != null) {
      final date = HttpDate.parse(expires);
      return date.difference(DateTime.now());
    }

    return null;
  }

  Response _toResponse(CacheEntry entry, RequestOptions options) {
    return Response(
      requestOptions: options,
      data: entry.data,
      statusCode: 200,
      statusMessage: 'OK (From Cache)',
      // Build a new map: never mutate the cached entry's headers in place.
      headers: Headers.fromMap({
        ...entry.headers,
        'x-from-cache': ['true'],
      }),
    );
  }

  // noCache when absent: caching is opt-in per request.
  static HttpCachePolicy _cachePolicy(dynamic raw) {
    return raw is HttpCachePolicy ? raw : HttpCachePolicy.noCache;
  }
}
