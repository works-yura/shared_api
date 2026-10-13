import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

class _Socket implements io.Socket {
  final handlers = <String, void Function(dynamic)>{};
  final emitted = <String>[];
  bool disposed = false;

  void fire(String event, [dynamic data]) => handlers[event]?.call(data);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #onConnect)
      handlers['connect'] = invocation.positionalArguments[0];
    if (name == #onDisconnect)
      handlers['disconnect'] = invocation.positionalArguments[0];
    if (name == #onConnectError)
      handlers['connect_error'] = invocation.positionalArguments[0];
    if (name == #on) {
      handlers[invocation.positionalArguments[0] as String] =
          invocation.positionalArguments[1];
    }
    if (name == #emit) emitted.add(invocation.positionalArguments[0] as String);
    if (name == #dispose) disposed = true;
    return this;
  }
}

class _Session implements HttpSession<TokenState> {
  TokenState? value;
  int reads = 0;

  @override
  Future<TokenState?> read() async {
    reads++;
    return value;
  }

  @override
  Stream<TokenState?> get status => const Stream.empty();

  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<void> update(TokenState token) async {
    value = token;
  }
}

void main() {
  test('login authenticates the socket before publishing connected', () async {
    final session = _Session();
    final sockets = <_Socket>[];
    final streaming = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: const ApiCredentials(
        host: '127.0.0.1',
        clientID: 'test',
        clientSecret: 'test',
      ),
      session: session,
      createSocket: (_, __) {
        final socket = _Socket();
        sockets.add(socket);
        return socket;
      },
    );

    await streaming.connect();
    expect(sockets, isEmpty);
    session.value = TokenState.authorized(
      access: 'first.jwt.token',
      refresh: 'refresh',
      expiresIn: 3600,
    );
    await streaming.connect();
    expect(sockets, hasLength(1));
    expect(streaming.currentStatus, StreamingStatus.connecting);

    sockets.single.fire('connect');
    expect(sockets.single.emitted, ['auth']);
    expect(streaming.currentStatus, StreamingStatus.connecting);
    sockets.single.fire('authenticated', {'userId': 'user'});
    expect(streaming.currentStatus, StreamingStatus.connected);

    await streaming.disconnect();
    expect(streaming.currentStatus, StreamingStatus.disconnected);
    streaming.dispose();
  });

  test('rejected JWT is not retried by later HTTP activity', () async {
    final session = _Session()
      ..value = TokenState.authorized(
        access: 'bad.jwt.token',
        refresh: 'refresh',
        expiresIn: 3600,
      );
    final sockets = <_Socket>[];
    final streaming = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: const ApiCredentials(
        host: '127.0.0.1',
        clientID: 'test',
        clientSecret: 'test',
      ),
      session: session,
      createSocket: (_, __) {
        final socket = _Socket();
        sockets.add(socket);
        return socket;
      },
    );

    await streaming.connect();
    sockets.single.fire('connect');
    sockets.single.fire('exception', {'message': 'Unauthorized'});
    expect(streaming.currentStatus, StreamingStatus.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 510));
    await streaming.connect();
    expect(sockets, hasLength(1));

    session.value = TokenState.authorized(
      access: 'new.jwt.token',
      refresh: 'refresh',
      expiresIn: 3600,
    );
    await Future<void>.delayed(const Duration(milliseconds: 510));
    await streaming.connect();
    expect(sockets, hasLength(2));
    sockets.last.fire('connect');
    sockets.last.fire('authenticated', {'userId': 'user'});
    expect(streaming.currentStatus, StreamingStatus.connected);
    streaming.dispose();
  });

  test('registration HTTP activity cannot open a socket without a JWT',
      () async {
    final session = _Session();
    var appCheckReads = 0;
    final socket = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: const ApiCredentials(
        host: '127.0.0.1',
        clientID: 'test',
        clientSecret: 'test',
      ),
      session: session,
      appCheckToken: () async {
        appCheckReads++;
        return 'app-check';
      },
    );

    await socket.connect();
    await socket.connect();
    session.value =
        TokenState.unauthorized(reason: UnauthorizedReason.manualLogout);
    await socket.connect();

    expect(session.reads, 3);
    expect(appCheckReads, 0);
    expect(socket.currentStatus, StreamingStatus.disconnected);
    socket.dispose();
  });

  test('login may connect immediately; logout cancels a pending handshake',
      () async {
    final session = _Session();
    final appCheck = Completer<String?>();
    final socket = SocketIOStreaming<TokenState, ApiCredentials>(
      credentials: const ApiCredentials(
        host: '127.0.0.1',
        clientID: 'test',
        clientSecret: 'test',
      ),
      session: session,
      appCheckToken: () => appCheck.future,
    );

    await socket.connect();
    session.value = TokenState.authorized(
      access: 'header.payload.signature',
      refresh: 'refresh',
      expiresIn: 3600,
    );
    final pending = socket.connect();
    await Future<void>.delayed(Duration.zero);
    expect(socket.currentStatus, StreamingStatus.connecting);

    await socket.disconnect();
    appCheck.complete('app-check');
    await pending;
    expect(socket.currentStatus, StreamingStatus.disconnected);
    socket.dispose();
  });

  group('WebSocket handshake auth', () {
    test('carries the App Check token next to the access token', () {
      expect(SocketIOStreaming.handshakeAuth('jwt', 'app-check'), {
        'token': 'jwt',
        'appCheck': 'app-check',
      });
    });

    test('without App Check the handshake is what old builds sent', () {
      expect(SocketIOStreaming.handshakeAuth('jwt', null), {'token': 'jwt'});
    });
  });

  group('tryAppCheckToken', () {
    test('returns the token', () async {
      expect(await tryAppCheckToken(() async => 't'), 't');
    });

    test('null for empty, failing or hanging providers', () async {
      expect(await tryAppCheckToken(() async => ''), isNull);
      expect(await tryAppCheckToken(() async => null), isNull);
      expect(
        await tryAppCheckToken(() async => throw StateError('no attestation')),
        isNull,
      );
      expect(
        await tryAppCheckToken(
          () => Completer<String?>().future,
          const Duration(milliseconds: 20),
        ),
        isNull,
      );
    });
  });
}
