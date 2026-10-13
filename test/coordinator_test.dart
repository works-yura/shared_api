import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

// ---------------------------------------------------------------------------
// Helpers / fakes
// ---------------------------------------------------------------------------

String _jwt(String sub) {
  String enc(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
  return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.${enc({'sub': sub})}.sig';
}

AuthorizedState _auth(String sub, {int expiresIn = 3600, String? refresh}) =>
    AuthorizedState(
      access: _jwt(sub),
      refresh: refresh ?? 'refresh-$sub',
      expiresIn: expiresIn,
    );

/// Scripted result for a refresh call.
typedef _Script = FutureOr<Try<HttpException, dynamic>> Function(int call);

class _FakeClient implements HttpClient<TokenState, ApiCredentials> {
  _FakeClient(this.script);

  _Script script;
  final List<HttpRequest> requests = [];

  @override
  Future<Try<HttpException, T>> execute<T>(
      HttpRequest<TokenState, ApiCredentials, T> request,
      {HttpCancelToken? cancelToken}) async {
    requests.add(request);
    final r = await script(requests.length - 1);
    return r.fold(
      (f) => Try.failed<HttpException, T>(f),
      (s) => Try.success<HttpException, T>(s as T),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnectivity implements NetworkConnectivity {
  final controller = StreamController<NetworkStatus>.broadcast();
  NetworkStatus current = NetworkStatus.online;

  void emit(NetworkStatus s) {
    current = s;
    controller.add(s);
  }

  @override
  Stream<NetworkStatus> get status => controller.stream;

  @override
  Future<NetworkStatus> get currentStatus async => current;
}

class _FakeStreaming implements Streaming {
  final statusController = StreamController<StreamingStatus>.broadcast();
  int connectCalls = 0;
  int disconnectCalls = 0;
  int disposeCalls = 0;
  bool connected = false;

  @override
  Stream<StreamingStatus> get status => statusController.stream;

  @override
  bool get isConnected => connected;

  @override
  StreamingStatus get currentStatus =>
      connected ? StreamingStatus.connected : StreamingStatus.disconnected;

  @override
  Future<void> connect() async {
    connectCalls++;
    connected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    connected = false;
  }

  @override
  void dispose() => disposeCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Observer implements HttpObserver {
  final List<bool> refreshResults = [];
  final List<HttpState> sessions = [];

  @override
  void onTokenRefresh(int attempt, Duration delay, bool isSuccessful) =>
      refreshResults.add(isSuccessful);

  @override
  void onSessionChanged(HttpState state) => sessions.add(state);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

HttpResponseException _httpError(int status) =>
    HttpResponseException(status: status, message: 'E$status', headers: {});

Try<HttpException, dynamic> _ok() => Try.success(TokensResponse(
    accessToken: 'new', refreshToken: 'new-refresh', expiresIn: 3600));

class _Harness {
  _Harness({
    HttpSession<TokenState>? session,
    _Script? script,
    RetryConfig retry =
        const RetryConfig(maxAttempts: 2, initialDelay: Duration(seconds: 1)),
    bool withStreaming = true,
    String Function(AuthorizedState state)? userIdResolver,
    RefreshRejectedPredicate isRefreshRejected = defaultIsRefreshRejected,
    Duration Function(AuthorizedState state)? refreshDelay,
  })  : session = session ?? InMemoryHttpSession<TokenState>(),
        client = _FakeClient(script ?? (_) => _ok()),
        streaming = withStreaming ? _FakeStreaming() : null {
    coordinator = ApiCoordinator(
      session: this.session,
      connectivity: connectivity,
      client: client,
      refreshRequestFactory: (t) => AuthRefreshRequest(refreshToken: t),
      streaming: streaming,
      cache: cache,
      userIdResolver: userIdResolver,
      refreshDelay: refreshDelay,
      isRefreshRejected: isRefreshRejected,
      observers: [observer],
      retry: retry,
    );
  }

  final HttpSession<TokenState> session;
  final _FakeClient client;
  final _FakeStreaming? streaming;
  final connectivity = _FakeConnectivity();
  final cache = MapHttpCache();
  final observer = _Observer();
  late final ApiCoordinator coordinator;

  final List<TokenState?> emitted = [];
  StreamSubscription? _sub;

  void setup() {
    _sub = session.status.listen(emitted.add);
    coordinator.setup();
  }

  Future<void> seedCache() => cache.set('k', 'v',
      expiresAt: DateTime.now().add(const Duration(hours: 1)));

  void dispose() {
    _sub?.cancel();
    coordinator.dispose();
  }
}

SharedApiSession _sharedSession(TokenState? stored) => SharedApiSession(
      onSave: (_) async {},
      onDelete: () async {},
      onLoad: () async => stored,
    );

void main() {
  // -------------------------------------------------------------------------
  group('custom refresh delay', () {
    test('refreshDelay decides when the refresh runs', () {
      fakeAsync((async) {
        final h = _Harness(refreshDelay: (_) => const Duration(minutes: 7));
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();

        async.elapse(const Duration(minutes: 6));
        expect(h.client.requests, isEmpty);
        async.elapse(const Duration(minutes: 2));
        expect(h.client.requests, hasLength(1));
        h.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  group('HTTP cache owner tracking', () {
    test('first session event (restore) does NOT clear the cache', () {
      fakeAsync((async) {
        final h = _Harness(session: _sharedSession(_auth('A')));
        h.seedCache();
        async.flushMicrotasks();
        h.setup(); // read() restores A and emits it
        async.flushMicrotasks();
        expect(h.emitted, hasLength(1));
        expect(h.cache.length, 1);
        h.dispose();
      });
    });

    test('first event being unauthorized does NOT clear the cache', () {
      fakeAsync((async) {
        final h = _Harness();
        h.seedCache();
        h.setup();
        h.session.update(
            TokenState.unauthorized(reason: UnauthorizedReason.manualLogout));
        async.flushMicrotasks();
        expect(h.cache.length, 1);
        h.dispose();
      });
    });

    test('user A -> unauthorized clears the cache', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        h.seedCache();
        async.flushMicrotasks();
        expect(h.cache.length, 1);

        h.session.update(
            TokenState.unauthorized(reason: UnauthorizedReason.manualLogout));
        async.flushMicrotasks();
        expect(h.cache.length, 0);
        h.dispose();
      });
    });

    test('user A -> clear() (null) clears the cache', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        h.seedCache();
        h.session.clear();
        async.flushMicrotasks();
        expect(h.cache.length, 0);
        h.dispose();
      });
    });

    test('user A -> user B clears the cache', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        h.seedCache();
        h.session.update(_auth('B'));
        async.flushMicrotasks();
        expect(h.cache.length, 0);
        h.dispose();
      });
    });

    test('user A -> user A (token refresh, same sub) does NOT clear', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A', refresh: 'r1'));
        async.flushMicrotasks();
        h.seedCache();
        h.session.update(_auth('A', refresh: 'r2'));
        async.flushMicrotasks();
        expect(h.cache.length, 1);
        h.dispose();
      });
    });

    test('restore A via SharedApiSession, then sign-in as B clears', () {
      fakeAsync((async) {
        final h = _Harness(session: _sharedSession(_auth('A')));
        h.setup();
        async.flushMicrotasks();
        h.seedCache();
        h.session.update(_auth('B'));
        async.flushMicrotasks();
        expect(h.cache.length, 0);
        h.dispose();
      });
    });

    AuthorizedState opaque(String access, String refresh) =>
        TokenState.authorized(
          access: access,
          refresh: refresh,
          expiresIn: 3600,
        ) as AuthorizedState;

    test('opaque tokens: switching accounts clears the cache', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(opaque('a1', 'ra'));
        async.flushMicrotasks();
        h.seedCache();
        async.flushMicrotasks();

        h.session.update(opaque('b1', 'rb'));
        async.flushMicrotasks();
        expect(h.cache.length, 0);
        h.dispose();
      });
    });

    test('userIdResolver keeps the cache across token rotation', () {
      fakeAsync((async) {
        final h = _Harness(userIdResolver: (_) => 'user-1');
        h.setup();
        h.session.update(opaque('a1', 'ra'));
        async.flushMicrotasks();
        h.seedCache();
        async.flushMicrotasks();

        h.session.update(opaque('a2', 'ra2'));
        async.flushMicrotasks();
        expect(h.cache.length, 1);
        h.dispose();
      });
    });

    test('unauthorized -> unauthorized does NOT clear (owner stays null)', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(
            TokenState.unauthorized(reason: UnauthorizedReason.manualLogout));
        async.flushMicrotasks();
        h.seedCache();
        h.session.clear();
        async.flushMicrotasks();
        expect(h.cache.length, 1);
        h.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  group('token refresh', () {
    test('authorized session schedules a refresh at refreshDelay', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        // expiresIn 3600 -> buffer 300s -> refresh in ~3300s.
        h.session.update(_auth('A', refresh: 'rt-A'));
        async.flushMicrotasks();
        expect(h.client.requests, isEmpty);
        expect(async.pendingTimers, hasLength(1));

        async.elapse(const Duration(seconds: 3200));
        expect(h.client.requests, isEmpty);

        async.elapse(const Duration(seconds: 120));
        expect(h.client.requests, hasLength(1));
        final req = h.client.requests.single as AuthRefreshRequest;
        expect(req.token, 'rt-A');
        h.dispose();
      });
    });

    test('short-lived token waits at least 30s before refreshing', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A', expiresIn: 5));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 29));
        expect(h.client.requests, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(h.client.requests, hasLength(1));
        h.dispose();
      });
    });

    test('new session event reschedules (old timer cancelled)', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A', expiresIn: 60, refresh: 'old'));
        async.flushMicrotasks();
        h.session.update(_auth('A', refresh: 'new'));
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(1));
        async.elapse(const Duration(seconds: 120));
        expect(h.client.requests, isEmpty);
        async.elapse(const Duration(hours: 1));
        expect(h.client.requests, hasLength(1));
        expect((h.client.requests.single as AuthRefreshRequest).token, 'new');
        h.dispose();
      });
    });

    test('refresh success notifies observers and does not retry', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        expect(h.client.requests, hasLength(1));
        expect(h.observer.refreshResults, [true]);
        expect(async.pendingTimers, isEmpty);
        // Session untouched by coordinator on success (client applies onSession).
        expect(h.emitted.whereType<UnauthorizedState>(), isEmpty);
        h.dispose();
      });
    });

    for (final status in [401, 403]) {
      test('refresh failure $status -> unauthorized(sessionExpired), no retry',
          () {
        fakeAsync((async) {
          final h = _Harness(script: (_) => Try.failed(_httpError(status)));
          h.setup();
          h.session.update(_auth('A'));
          async.flushMicrotasks();
          async.elapse(const Duration(hours: 1));

          expect(h.client.requests, hasLength(1));
          final last = h.emitted.last;
          expect(last, isA<UnauthorizedState>());
          expect((last as UnauthorizedState).reason,
              UnauthorizedReason.sessionExpired);
          expect(async.pendingTimers, isEmpty);
          expect(h.streaming!.disconnectCalls, greaterThan(0));
          h.dispose();
        });
      });
    }

    test('custom isRefreshRejected: 400 -> unauthorized, no retry', () {
      fakeAsync((async) {
        final h = _Harness(
          script: (_) => Try.failed(_httpError(400)),
          isRefreshRejected: (f) =>
              f is HttpResponseException && f.status == 400,
        );
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));

        expect(h.client.requests, hasLength(1));
        expect(h.emitted.last, isA<UnauthorizedState>());
        expect(async.pendingTimers, isEmpty);
        h.dispose();
      });
    });

    test('custom isRefreshRejected: 401 is retried, session kept', () {
      fakeAsync((async) {
        final h = _Harness(
          script: (call) => call == 0 ? Try.failed(_httpError(401)) : _ok(),
          isRefreshRejected: (_) => false,
        );
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        async.elapse(const Duration(seconds: 5));

        expect(h.client.requests, hasLength(2));
        expect(h.emitted.whereType<UnauthorizedState>(), isEmpty);
        h.dispose();
      });
    });

    test('refresh 401 with SharedApiSession emits unauthorized(sessionExpired)',
        () {
      fakeAsync((async) {
        final h = _Harness(
          session: _sharedSession(null),
          script: (_) => Try.failed(_httpError(401)),
        );
        h.setup();
        async.flushMicrotasks();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        final last = h.emitted.last as UnauthorizedState;
        expect(last.reason, UnauthorizedReason.sessionExpired);
        h.dispose();
      });
    });

    test('non-auth failure (500) retries with backoff then succeeds', () {
      fakeAsync((async) {
        final h = _Harness(
          script: (call) => call == 0 ? Try.failed(_httpError(500)) : _ok(),
        );
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        // First attempt failed, retry after initialDelay (1s) succeeded.
        expect(h.client.requests, hasLength(2));
        expect(h.observer.refreshResults, [false, true]);
        expect(async.pendingTimers, isEmpty);
        h.dispose();
      });
    });

    test('exception thrown by client is treated as failure and retried', () {
      fakeAsync((async) {
        final h = _Harness(
          script: (call) => call == 0 ? throw StateError('boom') : _ok(),
        );
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        expect(h.client.requests, hasLength(2));
        expect(h.observer.refreshResults, [false, true]);
        h.dispose();
      });
    });

    test('max attempts reached -> unauthorized(sessionExpired)', () {
      fakeAsync((async) {
        final h = _Harness(script: (_) => Try.failed(_httpError(500)));
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 3300)); // attempt #0
        expect(h.client.requests, hasLength(1));
        async.elapse(const Duration(seconds: 1)); // retry #1 (1s)
        expect(h.client.requests, hasLength(2));
        expect(h.emitted.last, isA<AuthorizedState>());
        async.elapse(const Duration(seconds: 2)); // retry #2 (2s)
        expect(h.client.requests, hasLength(3));

        final last = h.emitted.last;
        expect(last, isA<UnauthorizedState>());
        expect((last as UnauthorizedState).reason,
            UnauthorizedReason.sessionExpired);
        expect(async.pendingTimers, isEmpty);
        h.dispose();
      });
    });

    test('onRefreshMaxAttemptsReached() -> unauthorized(sessionExpired)', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        h.coordinator.onRefreshMaxAttemptsReached();
        async.flushMicrotasks();
        final last = h.emitted.last as UnauthorizedState;
        expect(last.reason, UnauthorizedReason.sessionExpired);
        expect(async.pendingTimers, isEmpty); // refresh timer stopped
        h.dispose();
      });
    });

    test('no refresh scheduled while offline', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.connectivity.emit(NetworkStatus.offline);
        async.flushMicrotasks();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
        h.dispose();
      });
    });

    test('network restored with token near expiry triggers refresh', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.connectivity.emit(NetworkStatus.offline);
        async.flushMicrotasks();
        h.session.update(_auth('A', expiresIn: 60));
        async.flushMicrotasks();
        h.connectivity.emit(NetworkStatus.online);
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(1));
        async.elapse(const Duration(seconds: 31));
        expect(h.client.requests, hasLength(1));
        h.dispose();
      });
    });

    test('network restored with long-lived token still schedules a refresh',
        () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.connectivity.emit(NetworkStatus.offline);
        async.flushMicrotasks();
        h.session.update(_auth('A')); // arrives while offline -> no timer
        async.flushMicrotasks();
        h.connectivity.emit(NetworkStatus.online);
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        expect(h.client.requests, hasLength(1));
        h.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  group('streaming', () {
    test('unauthorized session -> streaming.disconnect', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(
            TokenState.unauthorized(reason: UnauthorizedReason.manualLogout));
        async.flushMicrotasks();
        expect(h.streaming!.disconnectCalls, 1);
        expect(h.streaming!.connectCalls, 0);
        h.dispose();
      });
    });

    test('authorized session while online -> connect', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        expect(h.streaming!.connectCalls, 1);
        expect(h.streaming!.disconnectCalls, 0);
        h.dispose();
      });
    });

    test('new authorized session while connected -> disconnect + connect', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        h.session.update(_auth('A', refresh: 'r2'));
        async.flushMicrotasks();
        expect(h.streaming!.connectCalls, 2);
        expect(h.streaming!.disconnectCalls, 1);
        h.dispose();
      });
    });

    test('going offline disconnects; restore with session reconnects', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        h.connectivity.emit(NetworkStatus.offline);
        async.flushMicrotasks();
        expect(h.streaming!.disconnectCalls, 1);
        h.connectivity.emit(NetworkStatus.online);
        async.flushMicrotasks();
        expect(h.streaming!.connectCalls, 2);
        h.dispose();
      });
    });

    test('streaming status changes are forwarded to observers', () {
      fakeAsync((async) {
        final statuses = <Object>[];
        final h = _Harness();
        // Re-route via a dedicated observer capturing ws status.
        final obs = _WsObserver(statuses);
        final c = ApiCoordinator(
          session: h.session,
          connectivity: h.connectivity,
          client: h.client,
          refreshRequestFactory: (t) => AuthRefreshRequest(refreshToken: t),
          streaming: h.streaming,
          observers: [obs],
        )..setup();
        h.streaming!.statusController.add(StreamingStatus.connected);
        async.flushMicrotasks();
        expect(statuses, [StreamingStatus.connected]);
        c.dispose();
      });
    });
  });

  // -------------------------------------------------------------------------
  group('dispose', () {
    test('cancels pending refresh timer and disposes streaming', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        expect(async.pendingTimers, hasLength(1));
        h.dispose();
        expect(async.pendingTimers, isEmpty);
        expect(h.streaming!.disposeCalls, 1);
        async.elapse(const Duration(hours: 2));
        expect(h.client.requests, isEmpty);
      });
    });

    test('ignores session / network / streaming events after dispose', () {
      fakeAsync((async) {
        final h = _Harness();
        h.setup();
        async.flushMicrotasks();
        h.coordinator.dispose();
        h.seedCache();
        h.session.update(_auth('A'));
        h.session.update(_auth('B'));
        h.connectivity.emit(NetworkStatus.offline);
        h.connectivity.emit(NetworkStatus.online);
        h.streaming!.statusController.add(StreamingStatus.connected);
        async.flushMicrotasks();
        expect(h.cache.length, 1);
        expect(h.streaming!.connectCalls, 0);
        expect(h.streaming!.disconnectCalls, 0);
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(hours: 2));
        expect(h.client.requests, isEmpty);
      });
    });

    test('works without streaming / cache (null collaborators)', () {
      fakeAsync((async) {
        final h = _Harness(withStreaming: false);
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        h.session.update(
            TokenState.unauthorized(reason: UnauthorizedReason.manualLogout));
        async.flushMicrotasks();
        h.dispose();
        expect(async.pendingTimers, isEmpty);
      });
    });

    test('in-flight refresh failing after dispose does not schedule a retry',
        () {
      fakeAsync((async) {
        final pending = Completer<Try<HttpException, dynamic>>();
        final h = _Harness(script: (_) => pending.future);
        h.setup();
        h.session.update(_auth('A'));
        async.flushMicrotasks();
        async.elapse(const Duration(hours: 1));
        expect(h.client.requests, hasLength(1));

        h.dispose();
        pending.complete(Try.failed(_httpError(500)));
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);
      });
    });
  });
}

class _WsObserver implements HttpObserver {
  _WsObserver(this.statuses);
  final List<Object> statuses;

  @override
  void onWsStatusChanged(Object status) => statuses.add(status);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
