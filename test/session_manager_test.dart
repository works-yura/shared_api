import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/core/session/session.dart';
import 'package:shared_api/src/drivers/session/manager.dart';
import 'package:shared_api/src/drivers/session/state.dart';

String _b64(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');

String _jwt(Object? payload) =>
    '${_b64('{"alg":"HS256","typ":"JWT"}')}.${_b64(json.encode(payload))}.sig';

AuthorizedState _auth({
  String access = 'a.b.c',
  String refresh = 'r',
  int expiresIn = 3600,
  DateTime? createdAt,
}) =>
    AuthorizedState(
      access: access,
      refresh: refresh,
      expiresIn: expiresIn,
      createdAt: createdAt,
    );

/// Fake storage backing an [ApiSession] with call counters.
class _Storage {
  TokenState? stored;
  int loads = 0;
  int saves = 0;
  int deletes = 0;
  Completer<void>? loadGate;
  Object? loadError;
  Object? saveError;

  _Storage([this.stored]);

  ApiSession build({bool shared = false}) {
    Future<void> onSave(TokenState s) async {
      saves++;
      if (saveError != null) throw saveError!;
      stored = s;
    }

    Future<void> onDelete() async {
      deletes++;
      stored = null;
    }

    Future<TokenState?> onLoad() async {
      loads++;
      if (loadGate != null) await loadGate!.future;
      if (loadError != null) throw loadError!;
      return stored;
    }

    return shared
        ? SharedApiSession(onSave: onSave, onDelete: onDelete, onLoad: onLoad)
        : ApiSession(onSave: onSave, onDelete: onDelete, onLoad: onLoad);
  }
}

void main() {
  group('ApiSession.read', () {
    test('loads via onLoad once and caches across sequential reads', () async {
      final token = _auth();
      final storage = _Storage(token);
      final session = storage.build();

      expect(await session.read(), same(token));
      expect(await session.read(), same(token));
      expect(await session.read(), same(token));
      expect(storage.loads, 1);
    });

    test('concurrent reads call onLoad only once (lock)', () async {
      final token = _auth();
      final storage = _Storage(token)..loadGate = Completer<void>();
      final session = storage.build();

      final futures = List.generate(5, (_) => session.read());
      await Future<void>.delayed(Duration.zero);
      storage.loadGate!.complete();
      final results = await Future.wait(futures);

      expect(results, everyElement(same(token)));
      expect(storage.loads, 1);
    });

    test('emits loaded state on status stream', () async {
      final token = _auth();
      final session = _Storage(token).build();
      final events = <TokenState?>[];
      final sub = session.status.listen(events.add);

      await session.read();
      await session.read(); // cached: no second emission
      await Future<void>.delayed(Duration.zero);

      expect(events, [same(token)]);
      await sub.cancel();
    });

    test('onLoad returning null yields null and is cached', () async {
      final storage = _Storage();
      final session = storage.build();
      final events = <TokenState?>[];
      final sub = session.status.listen(events.add);

      expect(await session.read(), isNull);
      expect(await session.read(), isNull);
      await Future<void>.delayed(Duration.zero);

      // "No session" is cached: storage is read once, listeners notified once.
      expect(storage.loads, 1);
      expect(events, [null]);
      await sub.cancel();
    });

    test('onLoad throwing propagates, leaves cache empty, and retry works',
        () async {
      final token = _auth();
      final storage = _Storage(token)..loadError = StateError('disk');
      final session = storage.build();

      await expectLater(session.read(), throwsStateError);

      // Lock must be released after the error; next read retries.
      storage.loadError = null;
      expect(await session.read(), same(token));
      expect(storage.loads, 2);
    });

    test('update during in-flight load is not overwritten by stale load',
        () async {
      final stale = _auth(access: 'stale');
      final fresh = _auth(access: 'fresh');
      final storage = _Storage(stale)..loadGate = Completer<void>();
      final session = storage.build();

      final readFuture = session.read();
      final updateFuture = session.update(fresh); // queued behind lock
      await Future<void>.delayed(Duration.zero);
      storage.loadGate!.complete();

      expect(await readFuture, same(stale));
      await updateFuture;
      expect(await session.read(), same(fresh));
      expect(storage.loads, 1);
    });

    test('SharedApiSession behaves as ApiSession', () async {
      final token = _auth();
      final storage = _Storage(token);
      final session = storage.build(shared: true);

      expect(session, isA<ApiSession>());
      expect(session, isA<HttpSession<TokenState>>());
      expect(await session.read(), same(token));
      expect(await session.read(), same(token));
      expect(storage.loads, 1);
    });
  });

  group('ApiSession.update', () {
    test('authorized: persists via onSave, caches, emits', () async {
      final storage = _Storage();
      final session = storage.build();
      final token = _auth();
      final events = <TokenState?>[];
      final sub = session.status.listen(events.add);

      await session.update(token);
      await Future<void>.delayed(Duration.zero);

      expect(storage.saves, 1);
      expect(storage.stored, same(token));
      expect(events, [same(token)]);
      expect(await session.read(), same(token));
      expect(storage.loads, 0, reason: 'cached value used, no onLoad');
      await sub.cancel();
    });

    test('second update replaces cached value', () async {
      final storage = _Storage();
      final session = storage.build();
      final a = _auth(access: 'a');
      final b = _auth(access: 'b');

      await session.update(a);
      await session.update(b);

      expect(await session.read(), same(b));
      expect(storage.saves, 2);
    });

    test('onSave throwing propagates and does not emit', () async {
      final storage = _Storage()..saveError = Exception('io');
      final session = storage.build();
      final events = <TokenState?>[];
      final sub = session.status.listen(events.add);

      await expectLater(session.update(_auth()), throwsException);
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      // Not cached: a failed save must not leave an unsaved state in memory.
      expect(await session.read(), isNull);
      await sub.cancel();
    });

    test('unauthorized: calls onDelete, emits given reason, clears cache',
        () async {
      final token = _auth();
      final storage = _Storage();
      final session = storage.build();
      await session.update(token);

      final events = <TokenState?>[];
      final sub = session.status.listen(events.add);
      await session.update(
          TokenState.unauthorized(reason: UnauthorizedReason.sessionExpired));
      await Future<void>.delayed(Duration.zero);

      expect(storage.deletes, 1);
      expect(storage.saves, 1, reason: 'unauthorized is never saved');
      expect(events, hasLength(1));
      expect((events.single as UnauthorizedState).reason,
          UnauthorizedReason.sessionExpired);
      expect(await session.read(), isNull);
      expect(storage.loads, 0, reason: 'signed-out state is cached, no reload');
      await sub.cancel();
    });
  });

  group('ApiSession.clear', () {
    test('calls onDelete, emits UnauthorizedState, subsequent read is null',
        () async {
      final storage = _Storage();
      final session = storage.build();
      await session.update(_auth());

      final events = <TokenState?>[];
      final sub = session.status.listen(events.add);
      await session.clear();
      await Future<void>.delayed(Duration.zero);

      expect(storage.deletes, 1);
      expect(storage.stored, isNull);
      expect(events.single, isA<UnauthorizedState>());
      expect((events.single as UnauthorizedState).reason,
          UnauthorizedReason.manualLogout);
      expect(await session.read(), isNull);
      await sub.cancel();
    });

    test('read after clear returns null without reloading', () async {
      final token = _auth();
      final storage = _Storage(token);
      final session = storage.build();

      await session.read();
      await session.clear();

      expect(await session.read(), isNull);
      expect(storage.loads, 1);
    });
  });

  group('InMemoryHttpSession', () {
    test('read is null initially, update stores and emits, clear emits null',
        () async {
      final session = InMemoryHttpSession<TokenState>();
      final events = <TokenState?>[];
      final sub = session.status.listen(events.add);

      expect(await session.read(), isNull);
      final token = _auth();
      await session.update(token);
      expect(await session.read(), same(token));
      await session.clear();
      expect(await session.read(), isNull);
      await Future<void>.delayed(Duration.zero);

      expect(events, [same(token), null]);
      await sub.cancel();
    });
  });

  group('AuthorizedState.userId', () {
    test('returns sub from valid JWT', () {
      expect(_auth(access: _jwt({'sub': 'user-123', 'iat': 1})).userId,
          'user-123');
    });

    test('handles payload requiring base64 padding', () {
      // Different lengths exercise base64Url.normalize padding paths.
      for (final id in ['a', 'ab', 'abc', 'abcd']) {
        expect(_auth(access: _jwt({'sub': id})).userId, id);
      }
    });

    test('missing sub -> empty', () {
      expect(_auth(access: _jwt({'iat': 1})).userId, '');
    });

    test('non-string sub -> empty', () {
      expect(_auth(access: _jwt({'sub': 42})).userId, '');
    });

    test('non-map payload -> empty', () {
      expect(_auth(access: _jwt(['sub'])).userId, '');
      expect(_auth(access: _jwt('sub')).userId, '');
    });

    test('malformed token -> empty', () {
      expect(_auth(access: '').userId, '');
      expect(_auth(access: 'not-a-jwt').userId, '');
      expect(_auth(access: 'a.b').userId, '');
      expect(_auth(access: 'a.b.c.d').userId, '');
      expect(_auth(access: 'h.!!!invalid!!!.s').userId, '');
      expect(_auth(access: 'h.${_b64('not json')}.s').userId, '');
    });
  });

  group('AuthorizedState expiry', () {
    test('fresh token is not expired and not expiring within small threshold',
        () {
      final s = _auth(expiresIn: 3600);
      expect(s.isExpired, isFalse);
      expect(s.willExpireIn(const Duration(minutes: 5)), isFalse);
    });

    test('willExpireIn true when threshold exceeds remaining lifetime', () {
      final s = _auth(expiresIn: 3600);
      expect(s.willExpireIn(const Duration(hours: 2)), isTrue);
    });

    test('past expiry -> isExpired and willExpireIn(zero)', () {
      final s = _auth(
        expiresIn: 60,
        createdAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      expect(s.isExpired, isTrue);
      expect(s.willExpireIn(Duration.zero), isTrue);
    });

    test('boundary: 100s remaining vs 90s/110s threshold', () {
      final s = _auth(
        expiresIn: 200,
        createdAt: DateTime.now().subtract(const Duration(seconds: 100)),
      );
      expect(s.willExpireIn(const Duration(seconds: 90)), isFalse);
      expect(s.willExpireIn(const Duration(seconds: 110)), isTrue);
    });

    test('createdAt defaults to now', () {
      final before = DateTime.now();
      final s = _auth();
      expect(s.createdAt.isBefore(before), isFalse);
      expect(s.createdAt.isAfter(DateTime.now()), isFalse);
    });

    test('expiresIn 0 is immediately expired', () {
      final s = _auth(
        expiresIn: 0,
        createdAt: DateTime.now().subtract(const Duration(milliseconds: 1)),
      );
      expect(s.isExpired, isTrue);
    });
  });

  group('TokenState factories', () {
    test('produce correct subtypes', () {
      expect(TokenState.authorized(access: 'a', refresh: 'r', expiresIn: 1),
          isA<AuthorizedState>());
      final u =
          TokenState.unauthorized(reason: UnauthorizedReason.accessDenied);
      expect(u, isA<UnauthorizedState>());
      expect((u as UnauthorizedState).reason, UnauthorizedReason.accessDenied);
    });
  });
}
