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

({Dio dio, _Adapter adapter}) _setup([CompressionInterceptor? interceptor]) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  final adapter = _Adapter();
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(interceptor ?? _gzip());
  return (dio: dio, adapter: adapter);
}

/// A JSON map whose encoded size is roughly [bytes].
Map<String, dynamic> _bigMap(int bytes) => {'payload': 'x' * bytes};

String _gunzipString(List<int> bytes) => utf8.decode(gzip.decode(bytes));

CompressionInterceptor _gzip({int threshold = 1024}) => CompressionInterceptor(
    compressor: const GzipCompressor(), threshold: threshold);

/// Custom format: proves new encodings plug in without touching the package.
class _ReverseCompressor extends RequestCompressor {
  const _ReverseCompressor();

  @override
  String get encoding => 'x-reverse';

  @override
  List<int> compress(List<int> bytes) =>
      bytes.reversed.toList().sublist(0, bytes.length ~/ 2);
}

void main() {
  test('default threshold is 1024 bytes', () {
    expect(_gzip().threshold, 1024);
    expect(const RequestCompression(GzipCompressor()).threshold, 1024);
  });

  test('large Map body is gzipped, headers set, decodes back to JSON',
      () async {
    final t = _setup();
    final body = _bigMap(4000);

    await t.dio.post<dynamic>('/upload', data: body);

    final req = t.adapter.requests.single;
    expect(req.headers['content-encoding'], 'gzip');
    // Response negotiation is not this interceptor's job.
    expect(req.headers.containsKey('accept-encoding'), false);
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
    final t = _setup(_gzip(threshold: 100));

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
    final t = _setup(_gzip(threshold: 100));
    // 60 chars, 120 utf8 bytes.
    final body = 'ї' * 60;

    await t.dio.post<dynamic>('/u',
        data: body, options: Options(contentType: 'text/plain'));

    expect(t.adapter.requests.single.headers['content-encoding'], 'gzip');
    expect(_gunzipString(t.adapter.bodies.single), body);
  });

  test('custom threshold param is honoured', () async {
    final t = _setup(_gzip(threshold: 10000));

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
    final t = _setup(_gzip(threshold: 10));
    final form = FormData.fromMap({'field': 'x' * 5000});

    await t.dio.post<dynamic>('/form', data: form);

    final req = t.adapter.requests.single;
    expect(req.headers.containsKey('content-encoding'), false);
    expect(req.data, same(form));
  });

  test('other object types (e.g. int) are passed through unchanged', () async {
    final t = _setup(_gzip(threshold: 0));

    await t.dio.post<dynamic>('/n', data: 123456789);

    final req = t.adapter.requests.single;
    expect(req.headers.containsKey('content-encoding'), false);
    expect(req.data, 123456789);
  });

  test('non-JSON-encodable Map falls back to original data (fail-safe)',
      () async {
    final t = _setup(_gzip(threshold: 0));
    final obj = Object();
    final body = {'o': obj};

    // The interceptor swallows the encode error; dio's own transformer then
    // fails on the same data, which is outside the interceptor's scope.
    await expectLater(
        t.dio.post<dynamic>('/bad', data: body), throwsA(isA<Object>()));
    expect(t.adapter.requests, isEmpty);
  });

  test('HttpConfig: compression disabled by default', () {
    expect(const HttpConfig().compression, isNull);
  });

  test('DioFactory installs CompressionInterceptor from HttpConfig', () {
    final dio = DioFactory(
      config: const HttpConfig(
        compression: RequestCompression(DeflateCompressor(), threshold: 2048),
      ),
    ).create();

    final installed = dio.interceptors.whereType<CompressionInterceptor>();
    expect(installed, hasLength(1));
    expect(installed.single.compressor, isA<DeflateCompressor>());
    expect(installed.single.threshold, 2048);
  });

  test('DioFactory does not install CompressionInterceptor by default', () {
    final dio = DioFactory(config: const HttpConfig()).create();
    expect(dio.interceptors.whereType<CompressionInterceptor>(), isEmpty);
  });

  test('deflate compressor sets deflate encoding and decodes with zlib',
      () async {
    final t =
        _setup(CompressionInterceptor(compressor: const DeflateCompressor()));
    final body = _bigMap(4000);

    await t.dio.post<dynamic>('/upload', data: body);

    expect(t.adapter.requests.single.headers['content-encoding'], 'deflate');
    expect(jsonDecode(utf8.decode(zlib.decode(t.adapter.bodies.single))), body);
  });

  test('custom compressor plugs in without package changes', () async {
    final t =
        _setup(CompressionInterceptor(compressor: const _ReverseCompressor()));

    await t.dio.post<dynamic>('/upload', data: 'x' * 4000);

    expect(t.adapter.requests.single.headers['content-encoding'], 'x-reverse');
    expect(t.adapter.bodies.single, hasLength(2000));
  });

  test('pre-encoded body (Content-Encoding set by caller) is not re-compressed',
      () async {
    final t = _setup(_gzip(threshold: 0));
    final pre = Uint8List.fromList(gzip.encode(utf8.encode('x' * 4000)));

    await t.dio.post<dynamic>('/upload',
        data: pre, options: Options(headers: {'Content-Encoding': 'gzip'}));

    expect(t.adapter.bodies.single, pre);
  });

  test('form-urlencoded Map is not JSON-encoded or compressed', () async {
    final t = _setup(_gzip(threshold: 0));

    await t.dio.post<dynamic>('/form',
        data: {'field': 'x' * 4000},
        options: Options(contentType: Headers.formUrlEncodedContentType));

    final req = t.adapter.requests.single;
    expect(req.headers.containsKey('content-encoding'), false);
    expect(utf8.decode(t.adapter.bodies.single), startsWith('field=xxx'));
  });

  test('body that does not shrink is sent uncompressed', () async {
    final t = _setup(_gzip(threshold: 0));
    // Random-looking bytes don't compress; gzip adds header overhead.
    final noise =
        Uint8List.fromList(List.generate(64, (i) => (i * 97 + 13) % 256));

    await t.dio.post<dynamic>('/bin', data: noise);

    expect(t.adapter.requests.single.headers.containsKey('content-encoding'),
        false);
    expect(t.adapter.bodies.single, noise);
  });
}
