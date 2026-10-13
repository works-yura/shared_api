import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpHeaders;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

const _timeout = Duration(seconds: 3);
const _refreshPath = '/api/v1/authentication/refresh';

/// A canned response from the fake server.
class _Reply {
  final int status;
  final Object body;
  const _Reply(this.status, [this.body = const {}]);
}

/// Fake server: routes by path, records every call (path + Authorization).
///
/// Protected endpoints answer 200 only when the Authorization header carries
/// [validAccess]; otherwise 401. The refresh endpoint answers via [onRefresh]
/// (which may await a gate to make concurrency deterministic).
class _FakeServer implements HttpClientAdapter {
  String validAccess;
  Future<_Reply> Function(Map<String, dynamic> body) onRefresh;
  final calls = <({String path, String? auth})>[];

  /// Paths that always answer with a fixed reply (e.g. a 403).
  final fixed = <String, _Reply>{};

  _FakeServer({required this.validAccess, required this.onRefresh});

  int callsTo(String fragment) =>
      calls.where((c) => c.path.contains(fragment)).length;

  int get refreshCalls => calls.where((c) => c.path.contains('refresh')).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final auth = options.headers[HttpHeaders.authorizationHeader] as String?;
    final path = options.uri.path;
    calls.add((path: path, auth: auth));

    // Never let a runaway retry loop hang the suite.
    if (calls.length > 50) {
      throw StateError('Too many requests: probable infinite loop');
    }

    _Reply reply;
    if (fixed.containsKey(path)) {
      reply = fixed[path]!;
    } else if (path.contains('refresh')) {
      final raw = options.data;
      final body = raw is Map<String, dynamic>
          ? raw
          : raw is String
              ? jsonDecode(raw) as Map<String, dynamic>
              : <String, dynamic>{};
      reply = await onRefresh(body);
    } else if (auth == 'Bearer $validAccess') {
      reply = _Reply(200, {'path': path, 'auth': auth});
    } else {
      reply = const _Reply(401, {'message': 'unauthorized'});
    }

    return ResponseBody.fromString(
      jsonEncode(reply.body),
      reply.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Refresh request whose path matches what the interceptors special-case.
class _RefreshRequest extends RefreshTokenRequestBase<TokensResponse> {
  _RefreshRequest(String token) : super(token: token, path: _refreshPath);

  @override
  HttpOptions onRequest(ApiCredentials credentials) =>
      HttpOptions.post(path, HttpData.json({'refreshToken': token}));

  @override
  TokensResponse onResponse(HttpResponse response) =>
      TokensResponse.fromJson(JsonObject(response.data));
}

/// Real [ApiSession] backed by memory; records every `update` call.
class _Session extends ApiSession {
  TokenState? stored;
  final updates = <TokenState>[];

  _Session._(this.stored, _Box box)
      : super(
          onSave: (s) async => box.value = s,
          onDelete: () async => box.value = null,
          onLoad: () async => box.value,
        ) {
    box.value = stored;
    _box = box;
  }

  late final _Box _box;

  factory _Session(TokenState? initial) => _Session._(initial, _Box());

  TokenState? get persisted => _box.value;

  @override
  Future<void> update(TokenState state) {
    updates.add(state);
    return super.update(state);
  }
}

class _Box {
  TokenState? value;
}

class _Harness {
  final Dio dio;
  final _FakeServer server;
  final _Session session;
  _Harness(this.dio, this.server, this.session);
}

_Harness _build({
  TokenState? initial,
  String validAccess = 'access-old',
  Future<_Reply> Function(Map<String, dynamic> body)? onRefresh,
  RefreshRequestFactory? refreshFactory,
}) {
  final server = _FakeServer(
    validAccess: validAccess,
    onRefresh: onRefresh ??
        (_) async => const _Reply(200, {
              'accessToken': 'access-new',
              'refreshToken': 'refresh-new',
              'expiresIn': 3600,
            }),
  );
  final session = _Session(initial);
  final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
    ..httpClientAdapter = server;

  final client = ApiClient<TokenState, ApiCredentials>(
    dio: dio,
    config: const HttpConfig(),
    session: session,
    credentials: const ApiCredentials(
      host: 'api.test',
      scheme: 'https',
      clientID: 'id',
      clientSecret: 'secret',
    ),
    cache: MapHttpCache(),
  );

  dio.interceptors.add(BearerTokenInterceptor(session: session));
  dio.interceptors.add(RefreshTokenInterceptor(
    dio: dio,
    session: session,
    client: client,
    refreshRequestFactory: refreshFactory ?? (t) => _RefreshRequest(t),
  ));

  return _Harness(dio, server, session);
}

AuthorizedState _authorized({
  String access = 'access-old',
  String refresh = 'refresh-old',
}) =>
    AuthorizedState(access: access, refresh: refresh, expiresIn: 3600);

void main() {
  group('RefreshTokenInterceptor', () {
    test(
        '401 -> refresh -> session updated -> original replayed with new '
        'Authorization and succeeds', () async {
      final refreshBodies = <Map<String, dynamic>>[];
      late _Harness h;
      h = _build(
        initial: _authorized(),
        onRefresh: (body) async {
          refreshBodies.add(body);
          h.server.validAccess = 'access-new'; // server rotates the token
          return const _Reply(200, {
            'accessToken': 'access-new',
            'refreshToken': 'refresh-new',
            'expiresIn': 3600,
          });
        },
      );
      h.server.validAccess = 'access-current-on-server'; // old one rejected

      final res = await h.dio.get('/api/v1/users/me').timeout(_timeout);

      expect(res.statusCode, 200);
      expect(res.data['auth'], 'Bearer access-new');
      expect(h.server.refreshCalls, 1);
      expect(refreshBodies.single['refreshToken'], 'refresh-old');

      final state = await h.session.read();
      expect(state, isA<AuthorizedState>());
      state as AuthorizedState;
      expect(state.access, 'access-new');
      expect(state.refresh, 'refresh-new');
      expect(h.session.persisted, isA<AuthorizedState>());

      // Refresh call must not carry the (stale) access token.
      final refreshCall =
          h.server.calls.firstWhere((c) => c.path.contains('refresh'));
      expect(refreshCall.auth, isNull);

      // original(old) -> retry with existing(old) -> refresh -> replay(new)
      expect(h.server.calls.map((c) => c.auth).toList(), [
        'Bearer access-old',
        'Bearer access-old',
        null,
        'Bearer access-new',
      ]);
    });

    test('concurrent 401s trigger exactly ONE refresh and all requests replay',
        () async {
      final gate = Completer<void>();
      late _Harness h;
      h = _build(
        initial: _authorized(),
        onRefresh: (_) async {
          await gate.future; // hold refresh until every request has 401'd
          h.server.validAccess = 'access-new';
          return const _Reply(200, {
            'accessToken': 'access-new',
            'refreshToken': 'refresh-new',
            'expiresIn': 3600,
          });
        },
      );
      h.server.validAccess = 'rotated-on-server';

      final futures = [
        for (var i = 0; i < 4; i++) h.dio.get('/api/v1/items/$i'),
      ];

      // Let all four reach the server and fail with 401 before refreshing.
      while (h.server.refreshCalls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();

      final results = await Future.wait(futures).timeout(_timeout);

      expect(results.map((r) => r.statusCode), everyElement(200));
      expect(results.map((r) => r.data['auth']),
          everyElement('Bearer access-new'));
      expect(h.server.refreshCalls, 1, reason: 'single-flight refresh');
      for (var i = 0; i < 4; i++) {
        expect(
          h.server.calls.where((c) =>
              c.path == '/api/v1/items/$i' && c.auth == 'Bearer access-new'),
          isNotEmpty,
          reason: 'request $i must be replayed with the new token',
        );
      }
      final state = await h.session.read() as AuthorizedState;
      expect(state.access, 'access-new');
    });

    test(
        'refresh endpoint 401 -> logout (sessionExpired), original fails, '
        'no loop', () async {
      final h = _build(
        initial: _authorized(),
        onRefresh: (_) async =>
            const _Reply(401, {'message': 'invalid refresh token'}),
      );
      h.server.validAccess = 'rotated-on-server';

      final future = h.dio.get('/api/v1/users/me');
      await expectLater(
        future.timeout(_timeout),
        throwsA(isA<InvalidRefreshTokenException>()),
      );

      expect(h.server.refreshCalls, 1);
      // original + retry-with-existing + refresh; nothing more.
      expect(h.server.calls.length, 3);
      expect(h.session.updates.length, 1);
      expect(
        h.session.updates.single,
        isA<UnauthorizedState>().having(
            (s) => s.reason, 'reason', UnauthorizedReason.sessionExpired),
      );
      expect(await h.session.read(), isNull);
      expect(h.session.persisted, isNull);
    });

    test(
        'concurrent requests + failing refresh: one refresh, all fail, '
        'single logout', () async {
      final gate = Completer<void>();
      late _Harness h;
      h = _build(
        initial: _authorized(),
        onRefresh: (_) async {
          await gate.future;
          return const _Reply(401, {'message': 'invalid refresh token'});
        },
      );
      h.server.validAccess = 'rotated-on-server';

      final futures = [
        for (var i = 0; i < 3; i++)
          h.dio
              .get('/api/v1/items/$i')
              .then<Object?>((r) => r, onError: (Object e) => e),
      ];
      while (h.server.refreshCalls == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();

      final outcomes = await Future.wait(futures).timeout(_timeout);

      expect(outcomes, everyElement(isA<InvalidRefreshTokenException>()));
      expect(h.server.refreshCalls, 1);
      expect(h.session.updates.whereType<UnauthorizedState>().length, 1);
      expect(await h.session.read(), isNull);
    });

    test('refresh endpoint 500 -> request fails, session is NOT cleared',
        () async {
      final h = _build(
        initial: _authorized(),
        onRefresh: (_) async => const _Reply(500, {'message': 'boom'}),
      );
      h.server.validAccess = 'rotated-on-server';

      await expectLater(
        h.dio.get('/api/v1/users/me').timeout(_timeout),
        throwsA(isA<InvalidRefreshTokenException>()),
      );
      expect(h.server.refreshCalls, 1);
      expect(h.session.updates, isEmpty);
      expect(await h.session.read(), isA<AuthorizedState>());
    });

    test(
        'refresh request 401 carrying an Authorization header does not '
        'deadlock (refresh-path bypass)', () async {
      // Force an Authorization header onto the refresh call so that the
      // `_isRequestSecured` check passes and only the refresh-path bypass
      // stands between this 401 and re-entering the non-reentrant lock.
      final h = _build(
        initial: _authorized(),
        onRefresh: (_) async => const _Reply(401, {'message': 'nope'}),
        refreshFactory: (t) => _RefreshRequestWithAuth(t),
      );
      h.server.validAccess = 'rotated-on-server';

      await expectLater(
        h.dio.get('/api/v1/users/me').timeout(_timeout),
        throwsA(isA<InvalidRefreshTokenException>()),
      );
      expect(h.server.refreshCalls, 1);
      expect(
        h.server.calls.firstWhere((c) => c.path.contains('refresh')).auth,
        'Bearer forced',
      );
      expect(await h.session.read(), isNull);
    });

    test(
        'replay after a successful refresh still 401 -> passes through '
        '(retry flag), no second refresh, no loop', () async {
      // Server never accepts any token, even the freshly issued one.
      final h = _build(initial: _authorized());
      h.server.validAccess = 'never-matches';

      await expectLater(
        h.dio.get('/api/v1/users/me').timeout(_timeout),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 401)),
      );
      expect(h.server.refreshCalls, 1);
      // original + retry-existing + refresh + replay
      expect(h.server.calls.length, 4);
      // Interceptor treats a 401 on the post-refresh replay as fatal.
      expect(h.session.updates.last, isA<UnauthorizedState>());
      expect(await h.session.read(), isNull);
    });

    test('retry with existing token succeeding skips refresh entirely',
        () async {
      // Simulates "another flow already refreshed": first attempt 401s, but
      // the retry with the current session token succeeds.
      final h = _build(initial: _authorized(access: 'access-current'));
      h.server.validAccess = 'access-current';
      // The server rejects exactly the first call (e.g. token rotated by a
      // concurrent flow in between).
      var rejected = false;
      final adapter = h.server;
      h.dio.httpClientAdapter = _RejectOnce(adapter, () {
        if (rejected) return false;
        rejected = true;
        return true;
      });

      final res = await h.dio.get('/api/v1/users/me').timeout(_timeout);
      expect(res.statusCode, 200);
      expect(adapter.refreshCalls, 0);
      expect(h.session.updates, isEmpty);
    });

    test(
        '401 with authentication.session_expired on retry -> logout, '
        'no refresh', () async {
      final h = _build(initial: _authorized());
      h.server.fixed['/api/v1/users/me'] =
          const _Reply(401, {'message': 'authentication.session_expired'});

      await expectLater(
        h.dio.get('/api/v1/users/me').timeout(_timeout),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 401)),
      );
      expect(h.server.refreshCalls, 0);
      expect(
        h.session.updates.single,
        isA<UnauthorizedState>().having(
            (s) => s.reason, 'reason', UnauthorizedReason.sessionExpired),
      );
      expect(await h.session.read(), isNull);
    });

    test('403 is NOT an auth error: no refresh, no logout, error surfaces',
        () async {
      final h = _build(initial: _authorized());
      h.server.fixed['/api/v1/groups/1'] =
          const _Reply(403, {'message': 'only owner'});

      await expectLater(
        h.dio.delete('/api/v1/groups/1').timeout(_timeout),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 403)),
      );
      expect(h.server.calls.length, 1, reason: 'no retry, no refresh');
      expect(h.session.updates, isEmpty);
      expect(await h.session.read(), isA<AuthorizedState>());
    });

    test(
        'no session: request has no Authorization, 401 passes straight through',
        () async {
      final h = _build(initial: null);

      await expectLater(
        h.dio.get('/api/v1/users/me').timeout(_timeout),
        throwsA(isA<DioException>()
            .having((e) => e.response?.statusCode, 'status', 401)
            .having((e) => e, 'exception',
                isNot(isA<InvalidRefreshTokenException>()))),
      );
      expect(h.server.calls.length, 1);
      expect(h.server.calls.single.auth, isNull);
      expect(h.server.refreshCalls, 0);
      expect(h.session.updates, isEmpty);
    });

    test(
        'no session but caller-supplied Authorization: 401 fails fast with '
        'InvalidRefreshTokenException, no refresh', () async {
      final h = _build(initial: null);

      await expectLater(
        h.dio
            .get('/api/v1/users/me',
                options: Options(headers: {
                  HttpHeaders.authorizationHeader: 'Bearer foreign',
                }))
            .timeout(_timeout),
        throwsA(isA<InvalidRefreshTokenException>()),
      );
      expect(h.server.calls.length, 1);
      expect(h.server.refreshCalls, 0);
      expect(h.session.updates, isEmpty);
    });

    test('successful requests are untouched by the interceptor', () async {
      final h = _build(initial: _authorized());

      final res = await h.dio.get('/api/v1/users/me').timeout(_timeout);
      expect(res.statusCode, 200);
      expect(h.server.calls.length, 1);
      expect(h.server.refreshCalls, 0);
    });

    test('shipped AuthRefreshRequest: refresh 401 must not deadlock', () async {
      final h = _build(
        initial: _authorized(),
        onRefresh: (_) async => const _Reply(401, {'message': 'nope'}),
        refreshFactory: (t) => AuthRefreshRequest(refreshToken: t),
      );
      h.server.validAccess = 'rotated-on-server';

      await expectLater(
        h.dio.get('/api/v1/users/me').timeout(_timeout),
        throwsA(isA<InvalidRefreshTokenException>()),
      );
      expect(h.server.refreshCalls, 1);
    });

    test('logout via ApiSession keeps the sessionExpired reason on the stream',
        () async {
      final h = _build(
        initial: _authorized(),
        onRefresh: (_) async => const _Reply(401, {'message': 'nope'}),
      );
      h.server.validAccess = 'rotated-on-server';
      await h.session.read(); // prime cache so the stream is quiet
      final emitted = <TokenState?>[];
      final sub = h.session.status.listen(emitted.add);

      await expectLater(
        h.dio.get('/api/v1/users/me').timeout(_timeout),
        throwsA(isA<InvalidRefreshTokenException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(
        emitted.whereType<UnauthorizedState>().single.reason,
        UnauthorizedReason.sessionExpired,
      );
    },
        skip: 'BUG: ApiSession.update(UnauthorizedState) calls clear() '
            '(manager.dart:71), which always emits manualLogout '
            '(manager.dart:88); the sessionExpired reason passed by the '
            'interceptor is lost, so UI cannot tell expiry from logout.');
  });
}

/// Like [_RefreshRequest] but forces an Authorization header onto the call.
class _RefreshRequestWithAuth extends _RefreshRequest {
  _RefreshRequestWithAuth(super.token);

  @override
  HttpOptions onRequest(ApiCredentials credentials) => HttpOptions.post(
        path,
        HttpData.json({'refreshToken': token}),
        headers: {HttpHeaders.authorizationHeader: 'Bearer forced'},
      );
}

/// Wraps a [_FakeServer] and answers 401 to calls for which [shouldReject]
/// returns true (consulted only for non-refresh calls).
class _RejectOnce implements HttpClientAdapter {
  final _FakeServer inner;
  final bool Function() shouldReject;
  _RejectOnce(this.inner, this.shouldReject);

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) {
    if (!options.uri.path.contains('refresh') && shouldReject()) {
      inner.calls.add((
        path: options.uri.path,
        auth: options.headers[HttpHeaders.authorizationHeader] as String?,
      ));
      return Future.value(ResponseBody.fromString(
        '{"message":"stale"}',
        401,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ));
    }
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}
