import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

const _custom = StreamingProtocol(
  typeField: 'kind',
  actionField: 'op',
  payloadField: 'body',
  correlationIdField: 'rid',
  messageIdField: 'mid',
  ackType: 'received',
  ackSuccessField: 'ok',
  ackErrorField: 'reason',
  ackCodeField: 'status',
  pingType: 'hb',
  pongType: 'hb_ack',
);

class _Echo extends BaseStreamingRequest<Map<String, dynamic>> {
  _Echo() : super('echo');

  @override
  Map<String, dynamic> get data => {'n': 1};

  @override
  Map<String, dynamic> onResponse(StreamingResponse response) => response.data;
}

class _Note extends StreamingEvent<String> {
  @override
  String get type => 'note';

  @override
  String onResponse(JsonObject json) => json.required<String>('text');
}

class _Session implements HttpSession<TokenState> {
  @override
  Future<TokenState?> read() async =>
      TokenState.authorized(access: 'jwt', refresh: 'r', expiresIn: 3600);

  @override
  Stream<TokenState?> get status => const Stream.empty();

  @override
  Future<void> clear() async {}

  @override
  Future<void> update(TokenState token) async {}
}

/// Minimal fake capturing what [MessagingService] does with the protocol.
class _Streaming implements Streaming {
  final sent = <dynamic>[];
  StreamingEvent? subscribed;
  final acks = StreamController<AckResponse>.broadcast();

  @override
  dynamic prepare(Map<String, dynamic> data) => data;

  @override
  bool get isConnected => true;

  @override
  void send(StreamingRequest request) =>
      sent.add((request as RawStreamingRequest).payload);

  @override
  Stream<T> on<T>(StreamingEvent<T> eventParser) {
    subscribed = eventParser;
    return acks.stream.cast<T>();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Local WebSocket server recording the handshake and every frame.
class _Server {
  late final io.HttpServer http;
  final requests = <Uri>[];
  final frames = StreamController<Map<String, dynamic>>.broadcast();
  final received = <Map<String, dynamic>>[];
  io.WebSocket? socket;

  Future<void> start() async {
    http = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      requests.add(req.uri);
      final ws = await io.WebSocketTransformer.upgrade(req);
      socket = ws;
      ws.listen((m) {
        final map = jsonDecode(m as String) as Map<String, dynamic>;
        received.add(map);
        frames.add(map);
      });
    });
  }

  void push(Map<String, dynamic> m) => socket!.add(jsonEncode(m));

  Future<Map<String, dynamic>> next(bool Function(Map<String, dynamic>) test) =>
      frames.stream.firstWhere(test).timeout(const Duration(seconds: 5));

  Future<void> close() => http.close(force: true);
}

WebSocketStreaming<TokenState, ApiCredentials> _client(
  _Server server, {
  StreamingProtocol protocol = StreamingProtocol.standard,
  String? tokenQueryParameter = 'token',
  Map<String, dynamic> Function(String token)? authMessage,
  String path = '/ws',
}) =>
    WebSocketStreaming<TokenState, ApiCredentials>(
      credentials: ApiCredentials(
        host: '127.0.0.1',
        port: server.http.port,
        scheme: 'http',
        clientID: 'test',
        clientSecret: 'test',
      ),
      codecs: const {'json': JsonCodec()},
      defaultProtocol: 'json',
      session: _Session(),
      heartbeatInterval: const Duration(milliseconds: 50),
      requestTimeout: const Duration(seconds: 5),
      protocol: protocol,
      tokenQueryParameter: tokenQueryParameter,
      authMessage: authMessage,
      path: path,
    );

void main() {
  group('StreamingProtocol defaults match the historic wire format', () {
    test('envelope', () {
      const options = StreamingOptions(
        action: 'a',
        data: {'x': 1},
        extras: {'e': true},
        correlationId: 'c',
      );
      expect(options.toJson(), {
        'action': 'a',
        'payload': {'x': 1},
        'correlation_id': 'c',
        'e': true,
      });
      expect(const StreamingOptions(action: 'a').toJson(),
          {'action': 'a', 'payload': {}});
    });

    test('ping, pong and ack names', () {
      const p = StreamingProtocol.standard;
      expect(p.ping, {'type': 'ping'});
      expect(p.pongType, 'pong');
      expect(p.messageIdField, 'msg_id');
      expect(p.typeOf({'type': 'pong'}), 'pong');
      expect(p.typeOf({'type': 1}), isNull);
    });

    test('AckEvent parses the default shape', () {
      final ack = AckEvent().onResponse(JsonObject(
          {'type': 'ack', 'msg_id': 'm', 'success': false, 'error': 'x'}));
      expect(AckEvent().type, 'ack');
      expect(ack.messageId, 'm');
      expect(ack.isSuccess, isFalse);
      expect(ack.error, 'x');
    });

    test('error interceptor maps the default NACK', () {
      const i = StreamingErrorInterceptor();
      expect(
        () => i.onResponse(const StreamingResponse(data: {
          'type': 'ack',
          'success': false,
          'error': 'no',
          'code': 409
        })),
        throwsA(isA<HttpException>()),
      );
      // Custom-shaped NACK is not recognised by the default protocol.
      i.onResponse(
          const StreamingResponse(data: {'kind': 'received', 'ok': false}));
    });
  });

  group('custom StreamingProtocol is honoured', () {
    test('envelope', () {
      const options =
          StreamingOptions(action: 'a', data: {'x': 1}, correlationId: 'c');
      expect(options.toJson(_custom), {
        'op': 'a',
        'body': {'x': 1},
        'rid': 'c',
      });
      expect(_custom.ping, {'kind': 'hb'});
    });

    test('AckEvent', () {
      final event = AckEvent(_custom);
      final ack = event.onResponse(JsonObject(
          {'kind': 'received', 'mid': 'm', 'ok': false, 'reason': 'r'}));
      expect(event.type, 'received');
      expect(ack.messageId, 'm');
      expect(ack.isSuccess, isFalse);
      expect(ack.error, 'r');
    });

    test('error interceptor', () {
      const i = StreamingErrorInterceptor(protocol: _custom);
      expect(
        () => i.onResponse(const StreamingResponse(data: {
          'kind': 'received',
          'ok': false,
          'reason': 'no',
          'status': 409,
        })),
        throwsA(isA<HttpException>()
            .having((e) => e.toString(), 'message', contains('no'))),
      );
      i.onResponse(
          const StreamingResponse(data: {'type': 'ack', 'success': false}));
    });

    test('MessagingService tags messages and parses acks with it', () async {
      final streaming = _Streaming();
      final outbox = InMemoryOutbox();
      final service = MessagingService(
          streaming: streaming, outbox: outbox, protocol: _custom)
        ..init();
      addTearDown(service.dispose);

      final id = await service.send(_Echo());
      expect(streaming.sent.single, {
        'op': 'echo',
        'body': {'n': 1},
        'mid': id,
      });
      expect((streaming.subscribed as AckEvent).protocol, same(_custom));
    });
  });

  group('WebSocketStreaming over a local server', () {
    late _Server server;

    setUp(() async {
      server = _Server();
      await server.start();
    });

    tearDown(() => server.close());

    test('defaults: /ws?token=, action/payload, correlation_id, ping/pong',
        () async {
      final client = _client(server);
      addTearDown(client.dispose);
      await client.connect();
      expect(client.isConnected, isTrue);

      expect(server.requests.single.path, '/ws');
      expect(server.requests.single.queryParameters, {'token': 'jwt'});

      final ping = server.next((m) => m['type'] == 'ping');
      expect(await ping, {'type': 'ping'});

      final response = client.sendRequest(_Echo());
      final request = await server.next((m) => m['action'] == 'echo');
      expect(request['payload'], {'n': 1});
      server.push({'type': 'pong'});
      server.push({'correlation_id': request['correlation_id'], 'ok': 1});
      expect((await response)['ok'], 1);

      final note = client.on(_Note()).first;
      server.push({'type': 'note', 'text': 'hi'});
      expect(await note.timeout(const Duration(seconds: 5)), 'hi');
    });

    test('custom: token kept out of URL, auth frame, custom field names',
        () async {
      final client = _client(
        server,
        protocol: _custom,
        tokenQueryParameter: null,
        authMessage: (t) => {'kind': 'auth', 'token': t},
        path: '/stream',
      );
      addTearDown(client.dispose);
      await client.connect();

      expect(server.requests.single.path, '/stream');
      expect(server.requests.single.queryParameters, isEmpty);
      expect(server.requests.single.toString(), isNot(contains('jwt')));

      final ping = server.next((m) => m['kind'] == 'hb');
      expect(await ping, {'kind': 'hb'});
      expect(server.received.first, {'kind': 'auth', 'token': 'jwt'});

      final response = client.sendRequest(_Echo());
      final request = await server.next((m) => m['op'] == 'echo');
      expect(request['body'], {'n': 1});
      expect(request.containsKey('correlation_id'), isFalse);

      final events = <String>[];
      final sub = client.on(_Note()).listen(events.add);
      addTearDown(sub.cancel);
      server.push({'kind': 'hb_ack'});
      server.push({'type': 'note', 'text': 'routed by the wrong field'});
      server.push({'kind': 'note', 'text': 'hi'});
      server.push({'rid': request['rid'], 'done': true});
      expect((await response)['done'], isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events, ['hi']);
    });
  });
}
