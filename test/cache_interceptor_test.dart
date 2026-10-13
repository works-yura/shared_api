import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

/// Fake adapter answering with scripted responses and recording requests.
class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  /// Builds the response for the n-th call (0-based).
  final ResponseBody Function(int call, RequestOptions options) respond;

  _Adapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(requests.length - 1, options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(
  String body, {
  int status = 200,
  Map<String, String> headers = const {},
}) {
  return ResponseBody.fromString(
    body,
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
      for (final e in headers.entries) e.key: [e.value],
    },
  );
}

Options _policy(HttpCachePolicy policy) =>
    Options(extra: {HttpConstants.cachePolicyKey: policy});

({Dio dio, _Adapter adapter, MapHttpCache cache}) _setup(
    ResponseBody Function(int call, RequestOptions options) respond) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..options.validateStatus = HttpValidator.validateStatus;
  final adapter = _Adapter(respond);
  dio.httpClientAdapter = adapter;
  final cache = MapHttpCache();
  dio.interceptors.add(CacheInterceptor(cache: cache, dio: dio));
  return (dio: dio, adapter: adapter, cache: cache);
}

Future<void> _expire(MapHttpCache cache, String key) async {
  final entry = (await cache.get(key))!;
  await cache.set(
    key,
    entry.data,
    expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    eTag: entry.eTag,
    lastModified: entry.lastModified,
    headers: entry.headers,
  );
}

const _key = 'https://api.test/items?&lang=';

void main() {
  test('noCache by default: every request hits the network', () async {
    final t = _setup((call, _) => _json('{"n":$call}'));

    await t.dio.get<dynamic>('/items');
    await t.dio.get<dynamic>('/items');

    expect(t.adapter.requests, hasLength(2));
    expect(t.cache.length, 0);
  });

  test('useCache serves a fresh entry without network', () async {
    final t = _setup((call, _) => _json('{"n":$call}'));

    await t.dio
        .get<dynamic>('/items', options: _policy(HttpCachePolicy.useCache));
    final res = await t.dio
        .get<dynamic>('/items', options: _policy(HttpCachePolicy.useCache));

    expect(t.adapter.requests, hasLength(1));
    expect(res.data, {'n': 0});
    expect(res.headers.value('x-from-cache'), 'true');
  });

  test('useCache revalidates an expired entry with ETag and handles 304',
      () async {
    final t = _setup((call, options) => call == 0
        ? _json('{"n":0}', headers: {'etag': '"v1"'})
        : _json('', status: 304));

    await t.dio
        .get<dynamic>('/items', options: _policy(HttpCachePolicy.useCache));
    await _expire(t.cache, _key);

    final res = await t.dio
        .get<dynamic>('/items', options: _policy(HttpCachePolicy.useCache));

    expect(t.adapter.requests[1].headers['If-None-Match'], '"v1"');
    expect(res.statusCode, 200);
    expect(res.data, {'n': 0});
    expect(res.headers.value('x-cache-stale'), isNull);
    expect((await t.cache.get(_key))!.isExpired, isFalse);
  });

  test('304 for an evicted entry re-fetches unconditionally', () async {
    late MapHttpCache cache;
    final t = _setup((call, options) {
      if (call == 0) return _json('{"n":0}', headers: {'etag': '"v1"'});
      if (call == 1) {
        // Entry disappears while the conditional request is in flight.
        unawaited(cache.clear());
        return _json('', status: 304);
      }
      return _json('{"n":2}');
    });
    cache = t.cache;

    await t.dio
        .get<dynamic>('/items', options: _policy(HttpCachePolicy.useCache));
    await _expire(t.cache, _key);

    final res = await t.dio
        .get<dynamic>('/items', options: _policy(HttpCachePolicy.useCache));

    expect(t.adapter.requests, hasLength(3));
    expect(t.adapter.requests[2].headers['If-None-Match'], isNull);
    expect(res.data, {'n': 2});
  });

  test(
      'staleWhileRevalidate serves stale data and refreshes once in background',
      () async {
    final t = _setup((call, _) => _json('{"n":$call}'));
    final options = _policy(HttpCachePolicy.staleWhileRevalidate);

    await t.dio.get<dynamic>('/items', options: options);
    await _expire(t.cache, _key);

    final results = await Future.wait([
      t.dio.get<dynamic>('/items', options: options),
      t.dio.get<dynamic>('/items', options: options),
    ]);

    for (final res in results) {
      expect(res.data, {'n': 0});
      expect(res.headers.value('x-cache-stale'), 'true');
    }

    // Let the background refresh complete.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(t.adapter.requests, hasLength(2), reason: 'single revalidation');
    final next = await t.dio.get<dynamic>('/items', options: options);
    expect(next.data, {'n': 1});
    expect(next.headers.value('x-cache-stale'), isNull);
  });

  test('onlyCache rejects on miss', () async {
    final t = _setup((call, _) => _json('{}'));

    await expectLater(
      t.dio.get<dynamic>('/items', options: _policy(HttpCachePolicy.onlyCache)),
      throwsA(isA<DioException>()),
    );
    expect(t.adapter.requests, isEmpty);
  });

  test('Cache-Control no-store is never stored', () async {
    final t = _setup((call, _) =>
        _json('{}', headers: {'cache-control': 'no-store, max-age=60'}));

    await t.dio
        .get<dynamic>('/items', options: _policy(HttpCachePolicy.useCache));

    expect(t.cache.length, 0);
  });

  test('malformed Expires does not hang the request', () async {
    final t =
        _setup((call, _) => _json('{"ok":true}', headers: {'expires': '0'}));

    final res = await t.dio
        .get<dynamic>('/items', options: _policy(HttpCachePolicy.useCache))
        .timeout(const Duration(seconds: 2));

    expect(res.data, {'ok': true});
  });

  group('response Vary header', () {
    ResponseBody tenantBody(int call, RequestOptions options,
            {String vary = 'X-Tenant'}) =>
        _json('{"tenant":"${options.headers['x-tenant']}","call":$call}',
            headers: {'vary': vary, 'cache-control': 'max-age=60'});

    test('responses are cached per value of the varied request header',
        () async {
      final t = _setup((call, options) => tenantBody(call, options));
      final use = _policy(HttpCachePolicy.useCache);
      Options withTenant(String tenant) =>
          use.copyWith(headers: {'x-tenant': tenant});

      final a1 = await t.dio.get<dynamic>('/items', options: withTenant('a'));
      final b1 = await t.dio.get<dynamic>('/items', options: withTenant('b'));
      final a2 = await t.dio.get<dynamic>('/items', options: withTenant('a'));

      expect(a1.data['tenant'], 'a');
      expect(b1.data['tenant'], 'b');
      expect(a2.data['tenant'], 'a');
      expect(a2.headers.value('x-from-cache'), 'true');
      expect(t.adapter.requests, hasLength(2), reason: 'a, b; second a cached');
    });

    test('Vary: * is never served from cache', () async {
      final t = _setup((call, options) => tenantBody(call, options, vary: '*'));
      final use = _policy(HttpCachePolicy.useCache);

      await t.dio.get<dynamic>('/items', options: use);
      await t.dio.get<dynamic>('/items', options: use);

      expect(t.adapter.requests, hasLength(2));
      expect(t.cache.length, 0);
    });

    test('headers already part of the key do not create a vary index',
        () async {
      final t = _setup((call, options) =>
          tenantBody(call, options, vary: 'Accept-Language'));
      final use = _policy(HttpCachePolicy.useCache);

      await t.dio.get<dynamic>('/items', options: use);
      await t.dio.get<dynamic>('/items', options: use);

      expect(t.adapter.requests, hasLength(1));
      expect(t.cache.length, 1, reason: 'only the entry, no #vary index');
    });

    test('dropping Vary later removes the index', () async {
      var vary = 'X-Tenant';
      final t =
          _setup((call, options) => tenantBody(call, options, vary: vary));
      final use = _policy(HttpCachePolicy.refresh);
      Options withTenant(String tenant) => Options(
            extra: use.extra,
            headers: {'x-tenant': tenant},
          );

      await t.dio.get<dynamic>('/items', options: withTenant('a'));
      expect(t.cache.length, 2, reason: 'entry + #vary index');

      vary = '';
      await t.dio.get<dynamic>('/items', options: withTenant('a'));

      // Without Vary the entry is shared: another tenant now hits it.
      final shared = await t.dio.get<dynamic>('/items',
          options: Options(
            extra: _policy(HttpCachePolicy.useCache).extra,
            headers: {'x-tenant': 'b'},
          ));
      expect(shared.headers.value('x-from-cache'), 'true');
      expect(shared.data['tenant'], 'a');
    });
  });

  test('ApiClient accepts a custom CacheInterceptor', () {
    final dio = Dio();
    final cache = MapHttpCache();

    ApiClient<TokenState, ApiCredentials>(
      dio: dio,
      config: const HttpConfig(),
      session: SharedApiSession(
        onSave: (_) async {},
        onDelete: () async {},
        onLoad: () async => null,
      ),
      credentials: const ApiCredentials(host: 'api.test'),
      cache: cache,
      cacheInterceptor: (c) =>
          CacheInterceptor(cache: c, varyHeaders: const ['x-tenant']),
    );

    final installed = dio.interceptors.first as CacheInterceptor;
    expect(installed.varyHeaders, ['x-tenant']);
    expect(installed.cache, same(cache));
    expect(installed.dio, same(dio));
  });

  test('ApiClient installs a single CacheInterceptor first', () {
    final dio = Dio()..interceptors.add(InterceptorsWrapper());
    final cache = MapHttpCache();

    ApiClient<TokenState, ApiCredentials>(
      dio: dio,
      config: const HttpConfig(),
      session: SharedApiSession(
        onSave: (_) async {},
        onDelete: () async {},
        onLoad: () async => null,
      ),
      credentials: const ApiCredentials(
          host: 'api.test', clientID: '', clientSecret: ''),
      cache: cache,
    );

    final installed = dio.interceptors.whereType<CacheInterceptor>().toList();
    expect(installed, hasLength(1));
    expect(dio.interceptors.first, isA<CacheInterceptor>());
    expect(installed.single.dio, same(dio));
  });

  group('cache key', () {
    ({Dio dio, _Adapter adapter, MapHttpCache cache}) setupWith({
      List<String> varyHeaders = CacheInterceptor.defaultVaryHeaders,
      String Function(RequestOptions options)? cacheKeyBuilder,
    }) {
      final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
      final adapter = _Adapter((call, _) => _json('{"n":$call}'));
      dio.httpClientAdapter = adapter;
      final cache = MapHttpCache();
      dio.interceptors.add(CacheInterceptor(
        cache: cache,
        dio: dio,
        varyHeaders: varyHeaders,
        cacheKeyBuilder: cacheKeyBuilder,
      ));
      return (dio: dio, adapter: adapter, cache: cache);
    }

    Future<dynamic> get(Dio dio, Map<String, String> headers) async =>
        (await dio.get<dynamic>(
          '/items',
          queryParameters: {'b': 2, 'a': 1},
          options: Options(
            headers: headers,
            extra: {HttpConstants.cachePolicyKey: HttpCachePolicy.useCache},
          ),
        ))
            .data;

    test('default key varies by Accept-Language only (format unchanged)',
        () async {
      final t = setupWith();

      await get(t.dio, {'Accept-Language': 'uk', 'x-country-code': 'UA'});
      // Different country, same language: served from cache.
      final data =
          await get(t.dio, {'Accept-Language': 'uk', 'x-country-code': 'PL'});
      await get(t.dio, {'Accept-Language': 'en'});

      expect(data, {'n': 0});
      expect(t.adapter.requests, hasLength(2));
      expect(await t.cache.get('https://api.test/items?a=1&b=2&lang=uk'),
          isNotNull);
    });

    test('varyHeaders adds request headers to the key', () async {
      final t = setupWith(
        varyHeaders: const ['Accept-Language', 'x-country-code'],
      );

      await get(t.dio, {'Accept-Language': 'uk', 'x-country-code': 'UA'});
      await get(t.dio, {'Accept-Language': 'uk', 'x-country-code': 'PL'});
      final cached =
          await get(t.dio, {'Accept-Language': 'uk', 'X-Country-Code': 'UA'});

      expect(t.adapter.requests, hasLength(2));
      expect(cached, {'n': 0});
      expect(
        await t.cache
            .get('https://api.test/items?a=1&b=2&lang=uk&x-country-code=PL'),
        isNotNull,
      );
    });

    test('cacheKeyBuilder replaces the default key', () async {
      final t = setupWith(
        cacheKeyBuilder: (o) =>
            '${CacheInterceptor.defaultCacheKey(o)}|tenant=${o.headers['x-tenant']}',
      );

      await get(t.dio, {'x-tenant': 'a'});
      await get(t.dio, {'x-tenant': 'b'});
      await get(t.dio, {'x-tenant': 'a'});

      expect(t.adapter.requests, hasLength(2));
      expect(
        await t.cache.get('https://api.test/items?a=1&b=2&lang=|tenant=b'),
        isNotNull,
      );
    });
  });
}
