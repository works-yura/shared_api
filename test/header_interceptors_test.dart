import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

/// Fake adapter recording every RequestOptions and answering with a scripted
/// response (200 `{"ok":true}` by default).
class _Adapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  final ResponseBody Function(RequestOptions options)? respond;

  _Adapter([this.respond]);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond?.call(options) ??
        ResponseBody.fromString('{"ok":true}', 200, headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        });
  }

  @override
  void close({bool force = false}) {}
}

({Dio dio, _Adapter adapter}) _setup(
  Interceptor interceptor, {
  ResponseBody Function(RequestOptions options)? respond,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
  final adapter = _Adapter(respond);
  dio.httpClientAdapter = adapter;
  dio.interceptors.add(interceptor);
  return (dio: dio, adapter: adapter);
}

/// In-memory session whose state can be swapped between requests.
class _FakeSession implements HttpSession<TokenState> {
  TokenState? state;
  int reads = 0;

  _FakeSession([this.state]);

  @override
  Future<TokenState?> read() async {
    reads++;
    return state;
  }

  @override
  Future<void> update(TokenState token) async => state = token;

  @override
  Future<void> clear() async => state = null;

  @override
  Stream<TokenState?> get status => const Stream.empty();
}

AuthorizedState _auth(String access) =>
    AuthorizedState(access: access, refresh: 'r-$access', expiresIn: 3600);

ResponseBody _status(int status, String body,
        {String contentType = Headers.jsonContentType}) =>
    ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: [contentType],
    });

void main() {
  group('BearerTokenInterceptor', () {
    test('adds "Authorization: Bearer <access>" for AuthorizedState', () async {
      final t =
          _setup(BearerTokenInterceptor(session: _FakeSession(_auth('abc'))));

      await t.dio.get<dynamic>('/me');

      expect(t.adapter.requests.single.headers['Authorization'], 'Bearer abc');
    });

    test('no Authorization header when session is empty (null)', () async {
      final t = _setup(BearerTokenInterceptor(session: _FakeSession()));

      await t.dio.get<dynamic>('/me');

      expect(t.adapter.requests.single.headers.containsKey('Authorization'),
          false);
    });

    test('no Authorization header for UnauthorizedState', () async {
      final t = _setup(BearerTokenInterceptor(
        session: _FakeSession(
            const UnauthorizedState(reason: UnauthorizedReason.sessionExpired)),
      ));

      await t.dio.get<dynamic>('/me');

      expect(t.adapter.requests.single.headers.containsKey('Authorization'),
          false);
    });

    test('refresh requests are skipped and session is not read', () async {
      final session = _FakeSession(_auth('stale'));
      final t = _setup(BearerTokenInterceptor(session: session));

      await t.dio.post<dynamic>(
        '/auth/refresh',
        options: Options(extra: {HttpConstants.refreshRequestKey: true}),
      );

      expect(t.adapter.requests.single.headers.containsKey('Authorization'),
          false);
      expect(session.reads, 0);
    });

    test('refresh flag other than true does not skip the header', () async {
      final t =
          _setup(BearerTokenInterceptor(session: _FakeSession(_auth('abc'))));

      await t.dio.get<dynamic>(
        '/me',
        options: Options(extra: {HttpConstants.refreshRequestKey: false}),
      );

      expect(t.adapter.requests.single.headers['Authorization'], 'Bearer abc');
    });

    test('reads the session on every request (rotation is picked up)',
        () async {
      final session = _FakeSession(_auth('one'));
      final t = _setup(BearerTokenInterceptor(session: session));

      await t.dio.get<dynamic>('/a');
      session.state = _auth('two');
      await t.dio.get<dynamic>('/b');
      session.state = null;
      await t.dio.get<dynamic>('/c');

      expect(session.reads, 3);
      expect(t.adapter.requests[0].headers['Authorization'], 'Bearer one');
      expect(t.adapter.requests[1].headers['Authorization'], 'Bearer two');
      expect(t.adapter.requests[2].headers.containsKey('Authorization'), false);
    });

    test('overrides a caller-supplied Authorization when authorized', () async {
      final t =
          _setup(BearerTokenInterceptor(session: _FakeSession(_auth('abc'))));

      await t.dio.get<dynamic>('/me',
          options: Options(headers: {'Authorization': 'Basic xyz'}));

      expect(t.adapter.requests.single.headers['Authorization'], 'Bearer abc');
    });

    test('custom header name and value builder', () async {
      final t = _setup(BearerTokenInterceptor(
        session: _FakeSession(_auth('abc')),
        headerName: 'X-Api-Token',
        headerValue: (token) => 'Token $token',
      ));

      await t.dio.get<dynamic>('/me');

      final headers = t.adapter.requests.single.headers;
      expect(headers['X-Api-Token'], 'Token abc');
      expect(headers.containsKey('Authorization'), false);
    });

    test('keeps a caller-supplied Authorization when not authorized', () async {
      final t = _setup(BearerTokenInterceptor(session: _FakeSession()));

      await t.dio.get<dynamic>('/me',
          options: Options(headers: {'Authorization': 'Basic xyz'}));

      expect(t.adapter.requests.single.headers['Authorization'], 'Basic xyz');
    });
  });

  group('SubscriptionInterceptor', () {
    Future<({int calls, DioException error})> run402(ResponseBody body) async {
      var calls = 0;
      final t = _setup(
        SubscriptionInterceptor(onSubscriptionRequired: () => calls++),
        respond: (_) => body,
      );
      DioException? error;
      try {
        await t.dio.get<dynamic>('/premium');
      } on DioException catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'error must still propagate');
      return (calls: calls, error: error!);
    }

    test(
        '402 with top-level SUBSCRIPTION_REQUIRED calls callback once and '
        'propagates the error', () async {
      final r = await run402(
          _status(402, '{"code":"SUBSCRIPTION_REQUIRED","message":"pay"}'));

      expect(r.calls, 1);
      expect(r.error.type, DioExceptionType.badResponse);
      expect(r.error.response?.statusCode, 402);
      expect(r.error.response?.data['code'], 'SUBSCRIPTION_REQUIRED');
    });

    test('402 with SUBSCRIPTION_REQUIRED in metadata calls callback once',
        () async {
      final r = await run402(_status(402,
          '{"message":"pay","metadata":{"code":"SUBSCRIPTION_REQUIRED"}}'));

      expect(r.calls, 1);
      expect(r.error.response?.statusCode, 402);
    });

    test('top-level code wins over metadata code', () async {
      final r = await run402(_status(
          402, '{"code":"OTHER","metadata":{"code":"SUBSCRIPTION_REQUIRED"}}'));

      expect(r.calls, 0);
    });

    test('402 with another code does not call callback', () async {
      final r = await run402(_status(402, '{"code":"CARD_DECLINED"}'));

      expect(r.calls, 0);
      expect(r.error.response?.statusCode, 402);
    });

    test('402 without any code does not call callback', () async {
      final r = await run402(_status(402, '{"message":"pay"}'));
      expect(r.calls, 0);
    });

    test('other statuses with SUBSCRIPTION_REQUIRED do not call callback',
        () async {
      for (final status in [400, 401, 403, 500]) {
        final r =
            await run402(_status(status, '{"code":"SUBSCRIPTION_REQUIRED"}'));
        expect(r.calls, 0, reason: 'status $status');
        expect(r.error.response?.statusCode, status);
      }
    });

    test('402 with non-map body does not call callback', () async {
      final text = await run402(
          _status(402, 'SUBSCRIPTION_REQUIRED', contentType: 'text/plain'));
      expect(text.calls, 0);
      expect(text.error.response?.statusCode, 402);

      final list = await run402(_status(402, '["SUBSCRIPTION_REQUIRED"]'));
      expect(list.calls, 0);
      expect(list.error.response?.statusCode, 402);
    });

    test('network error (no response) does not call callback', () async {
      var calls = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://api.test'));
      dio.httpClientAdapter = _ThrowingAdapter();
      dio.interceptors
          .add(SubscriptionInterceptor(onSubscriptionRequired: () => calls++));

      await expectLater(
        dio.get<dynamic>('/x'),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.connectionError)),
      );
      expect(calls, 0);
    });

    test('402 with non-map metadata still propagates the original 402 error',
        () async {
      final r = await run402(_status(402, '{"metadata":"oops"}'));

      expect(r.calls, 0);
      expect(r.error.response?.statusCode, 402);
      expect(r.error.type, DioExceptionType.badResponse);
    });

    test('custom matches replaces the default contract', () async {
      var calls = 0;
      final t = _setup(
        SubscriptionInterceptor(
          onSubscriptionRequired: () => calls++,
          matches: (e) => e.response?.statusCode == 403,
        ),
        respond: (o) => o.path == '/limited'
            ? _status(403, '{"code":"PLAN_LIMIT"}')
            : _status(402, '{"code":"SUBSCRIPTION_REQUIRED"}'),
      );

      for (final path in ['/limited', '/premium']) {
        await expectLater(
            t.dio.get<dynamic>(path), throwsA(isA<DioException>()));
      }
      expect(calls, 1, reason: 'only the 403 matches');
    });
  });

  group('VersionInterceptor', () {
    test('sets X-App-Version and X-App-Build from providers', () async {
      final t = _setup(VersionInterceptor(
        getAppVersion: () async => '1.2.3',
        getBuildNumber: () async => '42',
      ));

      await t.dio.get<dynamic>('/x');

      final h = t.adapter.requests.single.headers;
      expect(h['X-App-Version'], '1.2.3');
      expect(h['X-App-Build'], '42');
    });

    test('providers are called once and cached across requests', () async {
      var versionCalls = 0, buildCalls = 0;
      var version = '1.0.0';
      final t = _setup(VersionInterceptor(
        getAppVersion: () async {
          versionCalls++;
          return version;
        },
        getBuildNumber: () async {
          buildCalls++;
          return '7';
        },
      ));

      await t.dio.get<dynamic>('/a');
      version = '2.0.0';
      await t.dio.get<dynamic>('/b');

      expect(versionCalls, 1);
      expect(buildCalls, 1);
      expect(t.adapter.requests[1].headers['X-App-Version'], '1.0.0');
    });

    test('empty values are sent as empty headers', () async {
      final t = _setup(VersionInterceptor(
        getAppVersion: () async => '',
        getBuildNumber: () async => '',
      ));

      await t.dio.get<dynamic>('/x');

      final h = t.adapter.requests.single.headers;
      expect(h['X-App-Version'], '');
      expect(h['X-App-Build'], '');
    });

    test('overwrites caller-supplied version headers', () async {
      final t = _setup(VersionInterceptor(
        getAppVersion: () async => '1.2.3',
        getBuildNumber: () async => '42',
      ));

      await t.dio.get<dynamic>('/x',
          options: Options(
              headers: {'X-App-Version': 'custom', 'X-App-Build': 'custom'}));

      final h = t.adapter.requests.single.headers;
      expect(h['X-App-Version'], '1.2.3');
      expect(h['X-App-Build'], '42');
    });
  });

  group('LanguageInterceptor', () {
    test('sets Accept-Language from provider', () async {
      final t = _setup(LanguageInterceptor(getLanguageCode: () async => 'uk'));

      await t.dio.get<dynamic>('/x');

      expect(t.adapter.requests.single.headers['accept-language'], 'uk');
    });

    test('provider is consulted on every request (language change applies)',
        () async {
      var lang = 'en';
      var calls = 0;
      final t = _setup(LanguageInterceptor(getLanguageCode: () async {
        calls++;
        return lang;
      }));

      await t.dio.get<dynamic>('/a');
      lang = 'de';
      await t.dio.get<dynamic>('/b');

      expect(calls, 2);
      expect(t.adapter.requests[0].headers['accept-language'], 'en');
      expect(t.adapter.requests[1].headers['accept-language'], 'de');
    });

    test('empty language code is sent as an empty header', () async {
      final t = _setup(LanguageInterceptor(getLanguageCode: () async => ''));

      await t.dio.get<dynamic>('/x');

      expect(t.adapter.requests.single.headers['accept-language'], '');
    });

    test('overwrites a caller-supplied Accept-Language', () async {
      final t = _setup(LanguageInterceptor(getLanguageCode: () async => 'uk'));

      await t.dio.get<dynamic>('/x',
          options: Options(headers: {'Accept-Language': 'fr'}));

      expect(t.adapter.requests.single.headers['accept-language'], 'uk');
    });
  });

  group('CountryInterceptor', () {
    test('sets x-country-code from provider', () async {
      final t = _setup(CountryInterceptor(getCountryCode: () async => 'UA'));

      await t.dio.get<dynamic>('/x');

      expect(t.adapter.requests.single.headers['x-country-code'], 'UA');
    });

    test('null country code adds no header', () async {
      final t = _setup(CountryInterceptor(getCountryCode: () async => null));

      await t.dio.get<dynamic>('/x');

      expect(t.adapter.requests.single.headers.containsKey('x-country-code'),
          false);
    });

    test('empty country code is sent as an empty header', () async {
      final t = _setup(CountryInterceptor(getCountryCode: () async => ''));

      await t.dio.get<dynamic>('/x');

      expect(t.adapter.requests.single.headers['x-country-code'], '');
    });

    test('provider is consulted on every request', () async {
      String? country = 'UA';
      final t = _setup(CountryInterceptor(getCountryCode: () async => country));

      await t.dio.get<dynamic>('/a');
      country = 'PL';
      await t.dio.get<dynamic>('/b');
      country = null;
      await t.dio.get<dynamic>('/c');

      expect(t.adapter.requests[0].headers['x-country-code'], 'UA');
      expect(t.adapter.requests[1].headers['x-country-code'], 'PL');
      expect(
          t.adapter.requests[2].headers.containsKey('x-country-code'), false);
    });

    test('overwrites caller header when a code is available', () async {
      final t = _setup(CountryInterceptor(getCountryCode: () async => 'UA'));

      await t.dio.get<dynamic>('/x',
          options: Options(headers: {'X-Country-Code': 'US'}));

      expect(t.adapter.requests.single.headers['x-country-code'], 'UA');
    });

    test('keeps caller header when provider returns null', () async {
      final t = _setup(CountryInterceptor(getCountryCode: () async => null));

      await t.dio.get<dynamic>('/x',
          options: Options(headers: {'X-Country-Code': 'US'}));

      expect(t.adapter.requests.single.headers['x-country-code'], 'US');
    });
  });
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    throw DioException(
        requestOptions: options, type: DioExceptionType.connectionError);
  }

  @override
  void close({bool force = false}) {}
}
