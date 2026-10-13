import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

/// Fake adapter recording RequestOptions and the raw bytes on the wire.
class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final List<Uint8List> bodies = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final builder = BytesBuilder();
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
    }
    bodies.add(builder.takeBytes());
    return ResponseBody.fromString('{"ok":true}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

({Dio dio, _Adapter adapter}) _setup([GzipInterceptor? interceptor]) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  final adapter = _Adapter();
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(interceptor ?? GzipInterceptor());
  return (dio: dio, adapter: adapter);
}

/// A JSON map whose encoded size is roughly [bytes].
Map<String, dynamic> _bigMap(int bytes) => {'payload': 'x' * bytes};

String _gunzipString(List<int> bytes) => utf8.decode(gzip.decode(bytes));

void main() {
  test('default threshold is 1024 bytes', () {
    expect(GzipInterceptor().compressionThreshold, 1024);
  });

  test('large Map body is gzipped, headers set, decodes back to JSON',
      () async {
    final t = _setup();
    final body = _bigMap(4000);

    await t.dio.post<dynamic>('/upload', data: body);

    final req = t.adapter.requests.single;
    expect(req.headers['content-encoding'], 'gzip');
    expect(req.headers['accept-encoding'], 'gzip');
    expect(req.data, isA<Uint8List>());

    final wire = t.adapter.bodies.single;
    expect(wire.length, lessThan(jsonEncode(body).length));
    expect(jsonDecode(_gunzipString(wire)), body);
  });

  test('large List body is gzipped and decodes back', () async {
    final t = _setup();
    final body = List.generate(300, (i) => {'id': i, 'name': 'item $i'});

    await t.dio.post<dynamic>('/bulk', data: body);

    expect(t.adapter.requests.single.headers['content-encoding'], 'gzip');
    expect(jsonDecode(_gunzipString(t.adapter.bodies.single)), body);
  });

  test('large String body is gzipped and decodes back (utf8 preserved)',
      () async {
    final t = _setup();
    final body = 'Привіт, світ! ' * 200;

    await t.dio.post<dynamic>('/text',
        data: body, options: Options(contentType: 'text/plain'));

    expect(t.adapter.requests.single.headers['content-encoding'], 'gzip');
    expect(_gunzipString(t.adapter.bodies.single), body);
  });

  test('large Uint8List body is gzipped and decodes back', () async {
    final t = _setup();
    final body = Uint8List.fromList(List.generate(5000, (i) => i % 256));

    await t.dio.post<dynamic>('/bin',
        data: body, options: Options(contentType: 'application/octet-stream'));

    expect(t.adapter.requests.single.headers['content-encoding'], 'gzip');
    expect(gzip.decode(t.adapter.bodies.single), body);
  });

  test('small body is left untouched', () async {
    final t = _setup();
    final body = {'a': 1};

    await t.dio.post<dynamic>('/small', data: body);

    final req = t.adapter.requests.single;
    expect(req.headers.containsKey('content-encoding'), false);
    expect(req.data, body);
    expect(jsonDecode(utf8.decode(t.adapter.bodies.single)), body);
  });

  test(
      'threshold is strict: exactly threshold bytes is not compressed, '
      'one more byte is', () async {
    final t = _setup(GzipInterceptor(compressionThreshold: 100));

    await t.dio.post<dynamic>('/a',
        data: 'a' * 100, options: Options(contentType: 'text/plain'));
    await t.dio.post<dynamic>('/b',
        data: 'a' * 101, options: Options(contentType: 'text/plain'));

    expect(
        t.adapter.requests[0].headers.containsKey('content-encoding'), false);
    expect(utf8.decode(t.adapter.bodies[0]), 'a' * 100);
    expect(t.adapter.requests[1].headers['content-encoding'], 'gzip');
    expect(_gunzipString(t.adapter.bodies[1]), 'a' * 101);
  });

  test('threshold measured in utf8 bytes, not characters', () async {
    final t = _setup(GzipInterceptor(compressionThreshold: 100));
    // 60 chars, 120 utf8 bytes.
    final body = 'ї' * 60;

    await t.dio.post<dynamic>('/u',
        data: body, options: Options(contentType: 'text/plain'));

    expect(t.adapter.requests.single.headers['content-encoding'], 'gzip');
    expect(_gunzipString(t.adapter.bodies.single), body);
  });

  test('custom threshold param is honoured', () async {
    final t = _setup(GzipInterceptor(compressionThreshold: 10000));

    await t.dio.post<dynamic>('/x', data: _bigMap(4000));

    expect(t.adapter.requests.single.headers.containsKey('content-encoding'),
        false);
  });

  test('GET without body is untouched', () async {
    final t = _setup();

    await t.dio.get<dynamic>('/items');

    final req = t.adapter.requests.single;
    expect(req.headers.containsKey('content-encoding'), false);
    expect(req.headers.containsKey('accept-encoding'), false);
    expect(req.data, isNull);
  });

  test('FormData body is not compressed', () async {
    final t = _setup(GzipInterceptor(compressionThreshold: 10));
    final form = FormData.fromMap({'field': 'x' * 5000});

    await t.dio.post<dynamic>('/form', data: form);

    final req = t.adapter.requests.single;
    expect(req.headers.containsKey('content-encoding'), false);
    expect(req.data, same(form));
  });

  test('other object types (e.g. int) are passed through unchanged', () async {
    final t = _setup(GzipInterceptor(compressionThreshold: 0));

    await t.dio.post<dynamic>('/n', data: 123456789);

    final req = t.adapter.requests.single;
    expect(req.headers.containsKey('content-encoding'), false);
    expect(req.data, 123456789);
  });

  test('non-JSON-encodable Map falls back to original data (fail-safe)',
      () async {
    final t = _setup(GzipInterceptor(compressionThreshold: 0));
    final obj = Object();
    final body = {'o': obj};

    // The interceptor swallows the encode error; dio's own transformer then
    // fails on the same data, which is outside the interceptor's scope.
    await expectLater(
        t.dio.post<dynamic>('/bad', data: body), throwsA(isA<Object>()));
    expect(t.adapter.requests, isEmpty);
  });

  test('HttpConfig defaults: useGzip=false, gzipThreshold=1024', () {
    const config = HttpConfig();
    expect(config.useGzip, false);
    expect(config.gzipThreshold, 1024);
  });

  test('DioFactory installs GzipInterceptor per HttpConfig.useGzip/threshold',
      () {
    final dio = DioFactory(
      config: const HttpConfig(useGzip: true, gzipThreshold: 2048),
    ).create();

    final gz = dio.interceptors.whereType<GzipInterceptor>();
    expect(gz, hasLength(1));
    expect(gz.single.compressionThreshold, 2048);
  });

  test('DioFactory does not install GzipInterceptor by default', () {
    final dio = DioFactory(config: const HttpConfig()).create();
    expect(dio.interceptors.whereType<GzipInterceptor>(), isEmpty);
  });
}
