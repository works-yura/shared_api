import 'package:shared_api/src/core/http/data.dart';
import 'package:shared_api/src/core/http/method.dart';
import 'package:shared_api/src/core/http/cancel.dart';

/// Policy for caching behavior on a per-request basis.
enum HttpCachePolicy {
  /// Standard behavior: try cache first, if expired or missing, fetch from network.
  useCache,

  /// Bypass cache and always fetch from network, then update cache.
  refresh,

  /// Bypass cache and always fetch from network, do NOT update cache.
  noCache,

  /// Only use cache, never hit the network. Fails if not in cache.
  onlyCache,
}

class HttpOptions {
  final String path;
  final HttpMethod method;
  final Map<String, dynamic>? queries;
  final Map<String, dynamic>? headers;
  final HttpData? data;
  final HttpCachePolicy cachePolicy;
  final HttpCancelToken? cancelToken;
  final Map<String, dynamic>? extra;
  final void Function(int progress, int total)? onReceive;
  final void Function(int progress, int total)? onSend;

  HttpOptions({
    required this.path,
    required this.method,
    this.queries,
    this.headers,
    this.data,
    this.cachePolicy = HttpCachePolicy.noCache,
    this.cancelToken,
    this.extra,
    this.onReceive,
    this.onSend,
  });

  HttpOptions copyWith({
    String? path,
    HttpMethod? method,
    Map<String, dynamic>? queries,
    Map<String, dynamic>? headers,
    HttpData? data,
    HttpCachePolicy? cachePolicy,
    final void Function(int progress, int total)? onReceive,
    final void Function(int progress, int total)? onSend,
  }) {
    return HttpOptions(
      path: path ?? this.path,
      method: method ?? this.method,
      queries: queries ?? this.queries,
      headers: headers ?? this.headers,
      data: data ?? this.data,
      cachePolicy: cachePolicy ?? this.cachePolicy,
      onReceive: onReceive ?? this.onReceive,
      onSend: onSend ?? this.onSend,
    );
  }

  factory HttpOptions.get(
    String path, {
    Map<String, dynamic>? queries,
    Map<String, dynamic>? headers,
    final void Function(int progress, int total)? onReceive,
    final void Function(int progress, int total)? onSend,
  }) {
    return HttpOptions(
      path: path,
      method: HttpMethod.GET,
      queries: queries,
      headers: headers,
      onReceive: onReceive,
      onSend: onSend,
    );
  }

  factory HttpOptions.post(
    String path,
    HttpData data, {
    Map<String, dynamic>? queries,
    Map<String, dynamic>? headers,
    final void Function(int progress, int total)? onReceive,
    final void Function(int progress, int total)? onSend,
    Map<String, dynamic>? extra,
  }) {
    return HttpOptions(
      path: path,
      method: HttpMethod.POST,
      data: data,
      queries: queries,
      headers: headers,
      onReceive: onReceive,
      onSend: onSend,
      extra: extra,
    );
  }

  factory HttpOptions.patch(
    String path,
    HttpData data, {
    Map<String, dynamic>? queries,
    Map<String, dynamic>? headers,
    final void Function(int progress, int total)? onReceive,
    final void Function(int progress, int total)? onSend,
    Map<String, dynamic>? extra,
  }) {
    return HttpOptions(
      path: path,
      method: HttpMethod.PATCH,
      data: data,
      queries: queries,
      headers: headers,
      onReceive: onReceive,
      onSend: onSend,
      extra: extra,
    );
  }

  factory HttpOptions.put(
    String path,
    HttpData data, {
    Map<String, dynamic>? queries,
    Map<String, dynamic>? headers,
    final void Function(int progress, int total)? onReceive,
    final void Function(int progress, int total)? onSend,
  }) {
    return HttpOptions(
      path: path,
      method: HttpMethod.PUT,
      data: data,
      queries: queries,
      headers: headers,
      onReceive: onReceive,
      onSend: onSend,
    );
  }

  factory HttpOptions.delete(
    String path,
    HttpData data, {
    Map<String, dynamic>? queries,
    Map<String, dynamic>? headers,
    final void Function(int progress, int total)? onReceive,
    final void Function(int progress, int total)? onSend,
  }) {
    return HttpOptions(
      path: path,
      method: HttpMethod.DELETE,
      data: data,
      queries: queries,
      headers: headers,
      onReceive: onReceive,
      onSend: onSend,
    );
  }

  factory HttpOptions.head(
    String path,
    HttpData data, {
    Map<String, dynamic>? queries,
    Map<String, dynamic>? headers,
    final void Function(int progress, int total)? onReceive,
    final void Function(int progress, int total)? onSend,
  }) {
    return HttpOptions(
      path: path,
      method: HttpMethod.HEAD,
      data: data,
      queries: queries,
      headers: headers,
      onReceive: onReceive,
      onSend: onSend,
    );
  }

  factory HttpOptions.options(
    String path,
    HttpData data, {
    Map<String, dynamic>? queries,
    Map<String, dynamic>? headers,
    final void Function(int progress, int total)? onReceive,
    final void Function(int progress, int total)? onSend,
  }) {
    return HttpOptions(
      path: path,
      method: HttpMethod.OPTIONS,
      data: data,
      queries: queries,
      headers: headers,
      onReceive: onReceive,
      onSend: onSend,
    );
  }
}
