import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';
import 'package:shared_api/src/drivers/http/cancel_token.dart';

/// Fake adapter answering with scripted responses and recording requests.
class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];

  /// Builds the response for the n-th call (0-based). May throw.
  final FutureOr<ResponseBody> Function(int call, RequestOptions options)
      respond;

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

ResponseBody _json(Object? body, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

/// Records every observer callback.
class _Observer implements HttpObserver {
  final List<(String, String, Map<String, dynamic>?)> requests = [];
  final List<(String, Duration, int)> responses = [];
  final List<HttpException> errors = [];

  @override
  void onRequest(String path, String method, Map<String, dynamic>? params) =>
      requests.add((path, method, params));

  @override
  void onResponse(String path, Duration duration, int statusCode) =>
      responses.add((path, duration, statusCode));

  @override
  void onError(HttpException exception, [StackTrace? stackTrace]) =>
      errors.add(exception);

  @override
  void onSessionChanged(HttpState state) {}

  @override
  void onTokenRefresh(int attempt, Duration delay, bool isSuccessful) {}

  @override
  void onWsStatusChanged(Object status) {}
}

class _Harness {
  final Dio dio;
  final _Adapter adapter;
  final ApiClient<TokenState, ApiCredentials> client;
  final ApiSession session;
  final _Observer observer;
  final List<TokenState> saved;

  _Harness(this.dio, this.adapter, this.client, this.session, this.observer,
      this.saved);
}

_Harness _setup(
  FutureOr<ResponseBody> Function(int call, RequestOptions options) respond, {
  ApiCredentials credentials =
      const ApiCredentials(host: 'api.test', clientID: '', clientSecret: ''),
  HttpConfig config = const HttpConfig(),
}) {
  final dio = Dio();
  final adapter = _Adapter(respond);
  dio.httpClientAdapter = adapter;
  final saved = <TokenState>[];
  final session = SharedApiSession(
    onSave: (s) async => saved.add(s),
    onDelete: () async {},
    onLoad: () async => null,
  );
  final observer = _Observer();
  final client = ApiClient<TokenState, ApiCredentials>(
    dio: dio,
    config: config,
    session: session,
    credentials: credentials,
    cache: MapHttpCache(),
    observers: [observer],
  );
  return _Harness(dio, adapter, client, session, observer, saved);
}

// ---------------------------------------------------------------------------
// Requests under test
// ---------------------------------------------------------------------------

class _User {
  final int id;
  final String name;
  _User(this.id, this.name);
}

class _GetUser extends JsonRequest<_User> {
  final HttpCachePolicy cachePolicy;
  _GetUser({this.cachePolicy = HttpCachePolicy.noCache}) : super('/users/1');

  @override
  HttpOptions onRequest(ApiCredentials credentials) => HttpOptions(
        path: path,
        method: HttpMethod.get,
        cachePolicy: cachePolicy,
      );

  @override
  _User onJsonResponse(JsonObject json, HttpResponse response) =>
      _User(json.required<int>('id'), json.required<String>('name'));
}

class _ListUsers extends JsonArrayRequest<_User> {
  final Map<String, dynamic>? queries;
  _ListUsers({this.queries}) : super('users');

  @override
  HttpOptions onRequest(ApiCredentials credentials) =>
      HttpOptions.get(path, queries: queries);

  @override
  _User mapItem(JsonObject json, HttpResponse response) =>
      _User(json.required<int>('id'), json.required<String>('name'));
}

/// `BaseRequest<void>` relying on the default [HttpRequest.onResponse].
class _VoidRequest extends BaseRequest<void> {
  final HttpMethod method;
  final HttpData? data;
  _VoidRequest(this.method, {this.data}) : super('/void');

  @override
  HttpOptions onRequest(ApiCredentials credentials) =>
      HttpOptions(path: path, method: method, data: data);
}

/// `BaseRequest<void>` with [VoidResponseMixin].
class _VoidMixinRequest extends BaseRequest<void>
    with VoidResponseMixin<TokenState, ApiCredentials> {
  _VoidMixinRequest() : super('/void');

  @override
  HttpOptions onRequest(ApiCredentials credentials) =>
      HttpOptions.post(path, HttpData.json({'a': 1}));
}

/// Default [HttpRequest.onResponse] with a concrete type.
class _TypedRequest<R> extends BaseRequest<R> {
  _TypedRequest() : super('/typed');

  @override
  HttpOptions onRequest(ApiCredentials credentials) => HttpOptions.get(path);
}

class _Token extends TokenResponse {
  _Token({
    required super.accessToken,
    required super.refreshToken,
    required super.expiresIn,
  });
}

class _SignIn extends BaseRequest<_Token> with TokenSessionMixin<_Token> {
  _SignIn() : super('/auth/sign-in');

  @override
  HttpOptions onRequest(ApiCredentials credentials) => HttpOptions.post(
        path,
        HttpData.json({'email': 'a@b.c', 'password': 'x'}),
      );

  @override
  _Token onResponse(HttpResponse response) {
    final json = JsonObject(response.data as Map<String, dynamic>);
    return _Token(
      accessToken: json.required<String>('accessToken'),
      refreshToken: json.required<String>('refreshToken'),
      expiresIn: json.required<int>('expiresIn'),
    );
  }
}

class _ServiceRequest extends BaseRequest<void> {
  _ServiceRequest() : super('/charge');

  @override
  String? get service => 'payments';

  @override
  HttpOptions onRequest(ApiCredentials credentials) => HttpOptions.get(path);
}

HttpException _failure<R>(Try<HttpException, R> result) =>
    result.fold((f) => f, (s) => fail('expected failure, got success($s)'));

R _success<R>(Try<HttpException, R> result) =>
    result.fold((f) => fail('expected success, got failure($f)'), (s) => s);

void main() {
  group('success', () {
    test('JsonRequest returns Try.success with onResponse result', () async {
      final t = _setup((_, __) => _json({'id': 1, 'name': 'Ann'}));

      final result = await t.client.execute(_GetUser());

      expect(result.isSuccess(), isTrue);
      final user = _success(result);
      expect(user.id, 1);
      expect(user.name, 'Ann');
    });

    test('JsonArrayRequest maps every element', () async {
      final t = _setup((_, __) => _json([
            {'id': 1, 'name': 'Ann'},
            {'id': 2, 'name': 'Bob'},
          ]));

      final users = _success(await t.client.execute(_ListUsers()));

      expect(users.map((u) => u.name), ['Ann', 'Bob']);
    });

    test('JsonArrayRequest returns empty list for non-list body', () async {
      final t = _setup((_, __) => _json({'id': 1}));

      final users = _success(await t.client.execute(_ListUsers()));

      expect(users, isEmpty);
    });

    test('BaseRequest<void> succeeds with default onResponse', () async {
      final t = _setup((_, __) => _json({'ignored': true}));

      final result = await t.client.execute(_VoidRequest(HttpMethod.get));

      expect(result.isSuccess(), isTrue);
    });

    test('BaseRequest<void> with VoidResponseMixin succeeds', () async {
      final t = _setup((_, __) => _json(null));

      final result = await t.client.execute(_VoidMixinRequest());

      expect(result.isSuccess(), isTrue);
    });

    test('default onResponse returns data when type matches', () async {
      final t = _setup((_, __) => _json({'k': 'v'}));

      final data =
          _success(await t.client.execute(_TypedRequest<Map<String, dynamic>>()));

      expect(data, {'k': 'v'});
    });
  });

  group('request building', () {
    test('URL built from credentials host/scheme/port/path + request path',
        () async {
      final t = _setup(
        (_, __) => _json({'id': 1, 'name': 'Ann'}),
        credentials: const ApiCredentials(
          host: 'api.test',
          scheme: 'https',
          port: 8443,
          path: '/v1/',
          clientID: '',
          clientSecret: '',
        ),
      );

      await t.client.execute(_GetUser());

      expect(t.adapter.requests.single.uri.toString(),
          'https://api.test:8443/v1/users/1');
    });

    test('missing scheme defaults to https; request path without slash',
        () async {
      final t = _setup((_, __) => _json([]));

      await t.client.execute(_ListUsers());

      final uri = t.adapter.requests.single.uri;
      expect(uri.scheme, 'https');
      expect(uri.host, 'api.test');
      expect(uri.path, '/users');
    });

    test('explicit http scheme is honoured', () async {
      final t = _setup(
        (_, __) => _json([]),
        credentials: const ApiCredentials(
            host: 'api.test', scheme: 'http', clientID: '', clientSecret: ''),
      );

      await t.client.execute(_ListUsers());

      expect(t.adapter.requests.single.uri.scheme, 'http');
    });

    test('service discovery uses config.services base URL', () async {
      final t = _setup(
        (_, __) => _json(null),
        config: const HttpConfig(
            services: {'payments': 'https://pay.test/api/'}),
      );

      await t.client.execute(_ServiceRequest());

      expect(t.adapter.requests.single.uri.toString(),
          'https://pay.test/api/charge');
    });

    test('queries are sent as query parameters', () async {
      final t = _setup((_, __) => _json([]));

      await t.client
          .execute(_ListUsers(queries: {'page': 2, 'q': 'a b'}));

      final req = t.adapter.requests.single;
      expect(req.queryParameters, {'page': 2, 'q': 'a b'});
      expect(req.uri.queryParameters, {'page': '2', 'q': 'a b'});
    });

    test('JSON body is sent as-is', () async {
      final t = _setup((_, __) => _json(null));

      await t.client.execute(
          _VoidRequest(HttpMethod.post, data: HttpData.json({'a': 1})));

      expect(t.adapter.requests.single.data, {'a': 1});
    });

    test('multipart body is sent as FormData', () async {
      final t = _setup((_, __) => _json(null));

      await t.client.execute(_VoidRequest(HttpMethod.post,
          data: HttpData.multipart({'field': 'value'})));

      final data = t.adapter.requests.single.data;
      expect(data, isA<FormData>());
      expect((data as FormData).fields.single,
          isA<MapEntry<String, String>>()
              .having((e) => e.key, 'key', 'field')
              .having((e) => e.value, 'value', 'value'));
    });

    for (final method in HttpMethod.values) {
      test('method ${method.name} sent as ${method.value}', () async {
        final t = _setup((_, __) => _json(null));

        final result = await t.client.execute(_VoidRequest(method));

        expect(result.isSuccess(), isTrue);
        expect(t.adapter.requests.single.method, method.value);
      });
    }

    for (final policy in HttpCachePolicy.values
        .where((p) => p != HttpCachePolicy.onlyCache)) {
      test('cachePolicy ${policy.name} passed through dio extra', () async {
        final t = _setup((_, __) => _json({'id': 1, 'name': 'Ann'}));

        await t.client.execute(_GetUser(cachePolicy: policy));

        expect(t.adapter.requests.single.extra[HttpConstants.cachePolicyKey],
            policy);
      });
    }

    test('default cachePolicy is noCache', () async {
      final t = _setup((_, __) => _json(null));

      await t.client.execute(_VoidRequest(HttpMethod.get));

      expect(t.adapter.requests.single.extra[HttpConstants.cachePolicyKey],
          HttpCachePolicy.noCache);
    });
  });

  group('session', () {
    test('TokenSessionMixin sign-in updates the session', () async {
      final t = _setup((_, __) => _json({
            'accessToken': 'acc',
            'refreshToken': 'ref',
            'expiresIn': 3600,
          }));

      final result = await t.client.execute(_SignIn());

      expect(_success(result).accessToken, 'acc');
      final state = await t.session.read();
      expect(
          state,
          isA<AuthorizedState>()
              .having((s) => s.access, 'access', 'acc')
              .having((s) => s.refresh, 'refresh', 'ref')
              .having((s) => s.expiresIn, 'expiresIn', 3600));
      expect(t.saved, hasLength(1));
      expect(t.saved.single, same(state));
    });

    test('onSession returning null leaves session untouched', () async {
      final t = _setup((_, __) => _json({'id': 1, 'name': 'Ann'}));
      final emitted = <TokenState?>[];
      final sub = t.session.status.listen(emitted.add);

      await t.client.execute(_GetUser());
      await Future<void>.delayed(Duration.zero);

      expect(t.saved, isEmpty);
      expect(emitted, isEmpty);
      expect(await t.session.read(), isNull);
      await sub.cancel();
    });

    test('failed sign-in does not update the session', () async {
      final t = _setup((_, __) => _json({'message': 'bad'}, status: 401));

      final result = await t.client.execute(_SignIn());

      expect(result.isFailed(), isTrue);
      expect(t.saved, isEmpty);
      expect(await t.session.read(), isNull);
    });
  });

  group('failures', () {
    test('bad response → Try.failed(HttpResponseException)', () async {
      final t = _setup((_, __) => _json({'message': 'Nope'}, status: 404));

      final e = _failure(await t.client.execute(_GetUser()));

      expect(e.type, HttpExceptionType.response);
      expect(
          e,
          isA<HttpResponseException>()
              .having((e) => e.status, 'status', 404)
              .having((e) => e.message, 'message', 'Nope'));
    });

    test('connection error → Try.failed(connection)', () async {
      final t = _setup((_, options) => throw DioException.connectionError(
          requestOptions: options, reason: 'down'));

      final e = _failure(await t.client.execute(_GetUser()));

      expect(e.type, HttpExceptionType.connection);
    });

    test('timeout → Try.failed(timeout)', () async {
      final t = _setup((_, options) => throw DioException.receiveTimeout(
          timeout: const Duration(seconds: 1), requestOptions: options));

      final e = _failure(await t.client.execute(_GetUser()));

      expect(e.type, HttpExceptionType.timeout);
    });

    test('cancelled via DioCancelToken → Try.failed(cancel)', () async {
      final t = _setup((_, __) => _json(null));
      final token = DioCancelToken()..cancel('stop');

      final e = _failure(await t.client
          .execute(_VoidRequest(HttpMethod.get), cancelToken: token));

      expect(e.type, HttpExceptionType.cancel);
      expect(t.adapter.requests, isEmpty);
    });

    test('non-Dio error from adapter → Try.failed(unknown)', () async {
      final t = _setup((_, __) => throw StateError('boom'));

      final e = _failure(await t.client.execute(_GetUser()));

      expect(e.type, HttpExceptionType.unknown);
      expect(e.message, contains('boom'));
    });

    test('onResponse type mismatch (StateError) → failed, not a crash',
        () async {
      final t = _setup((_, __) => _json({'not': 'an int'}));

      final result = await t.client.execute(_TypedRequest<int>());

      final e = _failure(result);
      expect(e.type, HttpExceptionType.unknown);
      expect(e.message, contains('type mismatch'));
      expect(t.observer.errors, [same(e)]);
    });

    test('JsonRequest with non-map body → failed, not a crash', () async {
      final t = _setup((_, __) => _json([1, 2]));

      final result = await t.client.execute(_GetUser());

      expect(_failure(result).type, HttpExceptionType.unknown);
    });
  });

  group('observers', () {
    test('onRequest and onResponse on success', () async {
      final t = _setup((_, __) => _json([]));

      await t.client.execute(_ListUsers(queries: {'page': 1}));

      expect(t.observer.requests, hasLength(1));
      final (path, method, params) = t.observer.requests.single;
      expect(path, 'users');
      expect(method, 'GET');
      expect(params, {'page': 1});

      expect(t.observer.responses, hasLength(1));
      final (rPath, duration, status) = t.observer.responses.single;
      expect(rPath, 'users');
      expect(duration, greaterThanOrEqualTo(Duration.zero));
      expect(status, 200);
      expect(t.observer.errors, isEmpty);
    });

    test('onRequest and onError on DioException, no onResponse', () async {
      final t = _setup((_, __) => _json({'message': 'x'}, status: 500));

      final e = _failure(await t.client.execute(_GetUser()));

      expect(t.observer.requests, hasLength(1));
      expect(t.observer.requests.single.$2, 'GET');
      expect(t.observer.responses, isEmpty);
      expect(t.observer.errors, [same(e)]);
    });

    test('every observer is notified', () async {
      final dio = Dio()..httpClientAdapter = _Adapter((_, __) => _json(null));
      final a = _Observer();
      final b = _Observer();
      final client = ApiClient<TokenState, ApiCredentials>(
        dio: dio,
        config: const HttpConfig(),
        session: SharedApiSession(
          onSave: (_) async {},
          onDelete: () async {},
          onLoad: () async => null,
        ),
        credentials: const ApiCredentials(
            host: 'api.test', clientID: '', clientSecret: ''),
        cache: MapHttpCache(),
        observers: [a, b],
      );

      await client.execute(_VoidRequest(HttpMethod.delete));

      for (final o in [a, b]) {
        expect(o.requests.single.$2, 'DELETE');
        expect(o.responses, hasLength(1));
      }
    });
  });
}
