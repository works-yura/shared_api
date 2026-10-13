import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

/// Hand-written fake of the [Streaming] interface.
///
/// Records everything passed to [send], exposes a controllable connection flag
/// and lets the test push ACK events through [emitAck].
class _FakeStreaming implements Streaming {
  bool connected;
  final List<StreamingRequest> sent = [];

  /// When non-null, [send] throws for the n-th (0-based) call.
  int? throwOnSendCall;
  int _sendCalls = 0;

  final StreamController<AckResponse> _acks =
      StreamController<AckResponse>.broadcast();

  _FakeStreaming({this.connected = true});

  List<dynamic> get sentPayloads =>
      sent.map((r) => (r as RawStreamingRequest).payload).toList();

  void emitAck(String id, {bool success = true}) =>
      _acks.add(AckResponse(messageId: id, isSuccess: success));

  @override
  dynamic prepare(Map<String, dynamic> data) => {'encoded': data};

  @override
  bool get isConnected => connected;

  @override
  void send(StreamingRequest request) {
    final call = _sendCalls++;
    if (throwOnSendCall == call) {
      throw StateError('sink closed');
    }
    sent.add(request);
  }

  @override
  Stream<T> on<T>(StreamingEvent<T> eventParser) {
    expect(eventParser, isA<AckEvent>());
    return _acks.stream.cast<T>();
  }

  bool get hasAckListener => _acks.hasListener;

  @override
  StreamingStatus get currentStatus =>
      connected ? StreamingStatus.connected : StreamingStatus.disconnected;

  @override
  List<StreamingInterceptor> get interceptors => const [];

  @override
  Stream<StreamingStatus> get status => const Stream.empty();

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<void> disconnect() async => connected = false;

  @override
  Future<R> sendRequest<R>(StreamingRequest<R> request) =>
      throw UnimplementedError();

  @override
  void registerPersistentRequest(StreamingRequest request) {}

  @override
  void unregisterPersistentRequest(StreamingRequest request) {}

  @override
  void dispose() {}
}

/// Insertion-ordered outbox that records calls (avoids createdAt ties).
class _RecordingOutbox implements Outbox {
  final List<OutboxEntry> entries = [];
  final List<String> deleted = [];
  final List<String> updated = [];

  @override
  Future<void> save(OutboxEntry entry) async => entries.add(entry);

  @override
  Future<void> delete(String id) async {
    deleted.add(id);
    entries.removeWhere((e) => e.id == id);
  }

  @override
  Future<List<OutboxEntry>> getAll() async => List.of(entries);

  @override
  Future<void> update(OutboxEntry entry) async {
    updated.add(entry.id);
    final i = entries.indexWhere((e) => e.id == entry.id);
    if (i >= 0) entries[i] = entry;
  }

  @override
  Future<void> clear() async => entries.clear();
}

class _Ping extends BaseStreamingRequest<void> {
  final int n;
  _Ping(this.n) : super('ping');

  @override
  Map<String, dynamic> get data => {'n': n};

  @override
  void onResponse(StreamingResponse response) {}
}

/// Lets queued microtasks / stream events drain.
Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  late _FakeStreaming client;
  late _RecordingOutbox outbox;
  late MessagingService service;

  setUp(() {
    client = _FakeStreaming();
    outbox = _RecordingOutbox();
    service = MessagingService(streaming: client, outbox: outbox)..init();
  });

  tearDown(() => service.dispose());

  group('send', () {
    test('while connected: persists entry and sends prepared payload',
        () async {
      final id = await service.send(_Ping(1));

      expect(id, hasLength(16));
      expect(outbox.entries, hasLength(1));
      final entry = outbox.entries.single;
      expect(entry.id, id);
      expect(entry.retryCount, 0);
      expect(entry.payload, {
        'encoded': {
          'action': 'ping',
          'payload': {'n': 1},
          'msg_id': id,
        }
      });

      expect(client.sent, hasLength(1));
      expect(client.sent.single, isA<RawStreamingRequest>());
      expect(client.sentPayloads.single, same(entry.payload));
    });

    test('while disconnected: only queued to outbox, not sent', () async {
      client.connected = false;

      final id = await service.send(_Ping(1));

      expect(client.sent, isEmpty);
      expect(outbox.entries.map((e) => e.id), [id]);
      expect(await service.pendingCount, 1);
    });

    test('each send gets a unique message id', () async {
      final a = await service.send(_Ping(1));
      final b = await service.send(_Ping(2));
      expect(a, isNot(b));
    });

    test('client.send throwing still leaves the entry in the outbox',
        () async {
      client.throwOnSendCall = 0;

      await expectLater(service.send(_Ping(1)), throwsStateError);

      expect(outbox.entries, hasLength(1));
      expect(await service.pendingCount, 1);
    });
  });

  group('flushPending', () {
    test('does nothing when disconnected', () async {
      client.connected = false;
      await service.send(_Ping(1));

      await service.flushPending();

      expect(client.sent, isEmpty);
      expect(outbox.updated, isEmpty);
      expect(outbox.entries.single.retryCount, 0);
    });

    test('sends pending entries in FIFO order and increments retryCount',
        () async {
      client.connected = false;
      final ids = [
        await service.send(_Ping(1)),
        await service.send(_Ping(2)),
        await service.send(_Ping(3)),
      ];
      client.connected = true;

      await service.flushPending();

      expect(
        client.sentPayloads.map((p) => (p as Map)['encoded']['msg_id']),
        ids,
      );
      expect(outbox.updated, ids);
      expect(outbox.entries.map((e) => e.retryCount), [1, 1, 1]);
      // Entries are kept until ACK arrives.
      expect(await service.pendingCount, 3);
    });

    test('FIFO with InMemoryOutbox ordered by createdAt', () async {
      final mem = InMemoryOutbox();
      final c = _FakeStreaming();
      final s = MessagingService(streaming: c, outbox: mem)..init();
      addTearDown(s.dispose);

      final base = DateTime(2024);
      // Saved out of order; outbox sorts by createdAt.
      await mem.save(OutboxEntry(
          id: 'c', payload: 'p3', createdAt: base.add(const Duration(seconds: 3))));
      await mem.save(OutboxEntry(id: 'a', payload: 'p1', createdAt: base));
      await mem.save(OutboxEntry(
          id: 'b', payload: 'p2', createdAt: base.add(const Duration(seconds: 1))));

      await s.flushPending();

      expect(c.sentPayloads, ['p1', 'p2', 'p3']);
    });

    test('repeated flushes keep incrementing retryCount for unacked entries',
        () async {
      client.connected = false;
      await service.send(_Ping(1));
      client.connected = true;

      await service.flushPending();
      await service.flushPending();
      await service.flushPending();

      expect(outbox.entries.single.retryCount, 3);
      expect(client.sent, hasLength(3));
    });

    test('send failure mid-flush: error propagates, entries are kept',
        () async {
      client.connected = false;
      await service.send(_Ping(1));
      await service.send(_Ping(2));
      client.connected = true;
      client.throwOnSendCall = 0;

      await expectLater(service.flushPending(), throwsStateError);

      // Failed entry kept with its retry already counted; nothing removed.
      expect(outbox.entries, hasLength(2));
      expect(outbox.entries.first.retryCount, 1);
      expect(outbox.deleted, isEmpty);

      // Next flush delivers everything.
      await service.flushPending();
      expect(client.sent, hasLength(2));
      expect(outbox.entries.map((e) => e.retryCount), [2, 1]);
    });

    test('empty outbox: no sends', () async {
      await service.flushPending();
      expect(client.sent, isEmpty);
    });
  });

  group('ACK handling', () {
    test('successful ack removes entry from outbox', () async {
      final id = await service.send(_Ping(1));
      final other = await service.send(_Ping(2));

      client.emitAck(id);
      await _pump();

      expect(outbox.deleted, [id]);
      expect(outbox.entries.map((e) => e.id), [other]);
      expect(await service.pendingCount, 1);
    });

    test('failed ack keeps entry for retry', () async {
      final id = await service.send(_Ping(1));

      client.emitAck(id, success: false);
      await _pump();

      expect(outbox.deleted, isEmpty);
      expect(outbox.entries.map((e) => e.id), [id]);
    });

    test('acked entries are not re-sent by flushPending', () async {
      client.connected = false;
      final a = await service.send(_Ping(1));
      final b = await service.send(_Ping(2));
      client.connected = true;

      client.emitAck(a);
      await _pump();
      await service.flushPending();

      expect(
        client.sentPayloads.map((p) => (p as Map)['encoded']['msg_id']),
        [b],
      );
    });

    test('ack for unknown id is harmless', () async {
      final id = await service.send(_Ping(1));
      client.emitAck('nope');
      await _pump();
      expect(outbox.entries.map((e) => e.id), [id]);
    });

    test('no ack listener before init()', () async {
      final c = _FakeStreaming();
      final o = _RecordingOutbox();
      final s = MessagingService(streaming: c, outbox: o);
      expect(c.hasAckListener, isFalse);
      s.init();
      expect(c.hasAckListener, isTrue);
      s.dispose();
    });
  });

  group('dispose', () {
    test('cancels ack subscription', () async {
      expect(client.hasAckListener, isTrue);
      service.dispose();
      expect(client.hasAckListener, isFalse);
    });

    test('acks after dispose are ignored', () async {
      final id = await service.send(_Ping(1));
      service.dispose();

      client.emitAck(id);
      await _pump();

      expect(outbox.deleted, isEmpty);
      expect(outbox.entries, hasLength(1));
    });

    test('dispose is idempotent and safe without init', () {
      service.dispose();
      service.dispose();
      MessagingService(streaming: _FakeStreaming(), outbox: _RecordingOutbox())
          .dispose();
    });

    test('send / flush / pendingCount do not crash after dispose', () async {
      service.dispose();
      await service.send(_Ping(1));
      await service.flushPending();
      expect(await service.pendingCount, 1);
    });
  });
}
