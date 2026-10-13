import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class _Socket implements io.Socket {
  final handlers = <String, void Function(dynamic)>{};
  final emitted = <String>[];
  final offed = <String>[];

  void fire(String event, [dynamic data]) => handlers[event]?.call(data);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    final args = invocation.positionalArguments;
    if (name == #onConnect) handlers['connect'] = args[0];
    if (name == #onDisconnect) handlers['disconnect'] = args[0];
    if (name == #onConnectError) handlers['connect_error'] = args[0];
    if (name == #on) handlers[args[0] as String] = args[1];
    if (name == #off) offed.add(args[0] as String);
    if (name == #emit) emitted.add(args[0] as String);
    return this;
  }
}

class _Session<S extends HttpState> implements HttpSession<S> {
  _Session(this.value);
  S? value;

  @override
  Future<S?> read() async => value;

  @override
  Stream<S?> get status => const Stream.empty();

  @override
  Future<void> clear() async => value = null;

  @override
  Future<void> update(S token) async => value = token;
}

/// An app-specific session state the driver knows nothing about.
class _ApiKeyState extends HttpState {
  const _ApiKeyState(this.key);
  final String key;
}

const _credentials = ApiCredentials(
  host: '127.0.0.1',
  clientID: 'test',
  clientSecret: 'test',
);

TokenState _authorized(String access) =>
    TokenState.authorized(access: access, refresh: 'r', expiresIn: 3600);

void main() {
  test('defaults: /ws, websocket only, {token, appCheck}, auth handshake',
      () async {
    final sockets = <_Socket>[];
    final options = <Map<String, dynamic>>[];
    final streaming = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: _credentials,
      session: _Session<TokenState>(_authorized('jwt')),
      appCheckToken: () async => 'ac',
      createSocket: (_, o) {
        options.add(o);
        return (sockets..add(_Socket())).last;
      },
    );
    addTearDown(streaming.dispose);

    await streaming.connect();
    expect(options.single['path'], '/ws');
    expect(options.single['transports'], ['websocket']);
    expect(options.single['auth'], {'token': 'jwt', 'appCheck': 'ac'});

    sockets.single.fire('connect');
    expect(sockets.single.emitted, ['auth']);
    sockets.single.fire('authenticated');
    expect(streaming.currentStatus, StreamingStatus.connected);
    expect(SocketIOStreaming.defaultReconnect.maxAttempts, 8);
    expect(SocketIOStreaming.defaultReconnect.initialDelay,
        const Duration(seconds: 1));
    expect(SocketIOStreaming.defaultReconnect.maxDelay,
        const Duration(seconds: 30));
  });

  test('custom path, transports, auth payload and handshake events', () async {
    final sockets = <_Socket>[];
    final options = <Map<String, dynamic>>[];
    final streaming = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: _credentials,
      session: _Session<TokenState>(_authorized('jwt')),
      path: '/socket.io',
      transports: const ['polling', 'websocket'],
      authPayload: (token, appCheck) => {'bearer': token},
      authEvent: 'login',
      authenticatedEvent: 'ready',
      rejectedEvent: 'denied',
      createSocket: (_, o) {
        options.add(o);
        return (sockets..add(_Socket())).last;
      },
    );
    addTearDown(streaming.dispose);

    await streaming.connect();
    expect(options.single['path'], '/socket.io');
    expect(options.single['transports'], ['polling', 'websocket']);
    expect(options.single['auth'], {'bearer': 'jwt'});

    final socket = sockets.single;
    socket.fire('connect');
    expect(socket.emitted, ['login']);
    socket.fire('authenticated');
    expect(streaming.currentStatus, StreamingStatus.connecting);
    socket.fire('ready');
    expect(streaming.currentStatus, StreamingStatus.connected);

    await streaming.disconnect();
    expect(socket.offed, containsAll(['ready', 'denied']));
  });

  test('custom rejected event stops retrying the same token', () async {
    final sockets = <_Socket>[];
    final streaming = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: _credentials,
      session: _Session<TokenState>(_authorized('jwt')),
      rejectedEvent: 'denied',
      createSocket: (_, __) => (sockets..add(_Socket())).last,
    );
    addTearDown(streaming.dispose);

    await streaming.connect();
    sockets.single.fire('connect');
    sockets.single.fire('exception');
    expect(streaming.currentStatus, StreamingStatus.connecting);
    sockets.single.fire('denied');
    expect(streaming.currentStatus, StreamingStatus.disconnected);
  });

  test('token resolver reads an app-specific session state', () async {
    final session = _Session<_ApiKeyState>(null);
    final options = <Map<String, dynamic>>[];
    final streaming = SocketIOStreaming<_ApiKeyState, ApiCredentials>(
      credentials: _credentials,
      session: session,
      accessToken: (state) => state?.key,
      createSocket: (_, o) {
        options.add(o);
        return _Socket();
      },
    );
    addTearDown(streaming.dispose);

    await streaming.connect();
    expect(options, isEmpty);

    session.value = const _ApiKeyState('key-1');
    await Future<void>.delayed(const Duration(milliseconds: 510));
    await streaming.connect();
    expect(options.single['auth'], {'token': 'key-1'});
  });

  test('default resolver ignores non-AuthorizedState sessions', () {
    expect(sessionAccessToken(_authorized('jwt')), 'jwt');
    expect(sessionAccessToken(const _ApiKeyState('k')), isNull);
    expect(
      sessionAccessToken(
          TokenState.unauthorized(reason: UnauthorizedReason.manualLogout)),
      isNull,
    );
    expect(sessionAccessToken(null), isNull);
  });

  test('reconnect policy caps attempts', () async {
    final sockets = <_Socket>[];
    final streaming = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: _credentials,
      session: _Session<TokenState>(_authorized('jwt')),
      reconnect: const RetryConfig(maxAttempts: 0),
      createSocket: (_, __) => (sockets..add(_Socket())).last,
    );
    addTearDown(streaming.dispose);

    await streaming.connect();
    sockets.single.fire('connect');
    sockets.single.fire('authenticated');
    sockets.single.fire('disconnect');
    // No attempts allowed: gives up straight away instead of backing off.
    expect(streaming.currentStatus, StreamingStatus.disconnected);
  });

  test('default reconnect policy backs off after a drop', () async {
    final sockets = <_Socket>[];
    final streaming = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: _credentials,
      session: _Session<TokenState>(_authorized('jwt')),
      createSocket: (_, __) => (sockets..add(_Socket())).last,
    );
    addTearDown(streaming.dispose);

    await streaming.connect();
    sockets.single.fire('connect');
    sockets.single.fire('authenticated');
    sockets.single.fire('disconnect');
    expect(streaming.currentStatus, StreamingStatus.reconnecting);
  });

  test('ackTimeout bounds sendRequest', () async {
    final sockets = <_Socket>[];
    final streaming = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: _credentials,
      session: _Session<TokenState>(_authorized('jwt')),
      ackTimeout: const Duration(milliseconds: 10),
      createSocket: (_, __) => (sockets..add(_Socket())).last,
    );
    addTearDown(streaming.dispose);

    await streaming.connect();
    sockets.single.fire('connect');
    sockets.single.fire('authenticated');

    await expectLater(
      streaming.sendRequest(_Echo()),
      throwsA(isA<TimeoutException>()),
    );
  });
}

class _Echo extends BaseStreamingRequest<void> {
  _Echo() : super('echo');

  @override
  void onResponse(StreamingResponse response) {}
}
