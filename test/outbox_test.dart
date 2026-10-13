import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/core/outbox/outbox.dart';
import 'package:shared_api/src/drivers/streaming/persistence/persistent_outbox.dart';

class FakeOutboxStorage implements OutboxStorage {
  final Map<String, Map<String, dynamic>> data = {};
  final Set<String> throwOnRead = {};

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    if (throwOnRead.contains(key)) throw StateError('corrupt $key');
    return data[key];
  }

  @override
  Future<void> write(String key, Map<String, dynamic> value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

void main() {
  group('OutboxEntry', () {
    test('roundtrip with Map payload', () {
      final e = OutboxEntry(
        id: 'abc',
        payload: {'event': 'x', 'n': 1},
        createdAt: DateTime.utc(2024, 1, 2, 3),
        retryCount: 2,
      );
      final json = e.toJson();
      expect(json['is_binary'], isFalse);
      final back = OutboxEntry.fromJson(json);
      expect(back.id, 'abc');
      expect(back.payload, {'event': 'x', 'n': 1});
      expect(back.createdAt, DateTime.utc(2024, 1, 2, 3));
      expect(back.retryCount, 2);
    });

    test('roundtrip with Uint8List payload', () {
      final e = OutboxEntry(
        id: 'bin',
        payload: Uint8List.fromList([1, 2, 255]),
        createdAt: DateTime.utc(2024),
      );
      final json = e.toJson();
      expect(json['is_binary'], isTrue);
      expect(json['payload'], isA<List<int>>());
      expect(json['payload'], isNot(isA<Uint8List>()));
      final back = OutboxEntry.fromJson(json);
      expect(back.payload, isA<Uint8List>());
      expect(back.payload, [1, 2, 255]);
    });

    test('defaults: generated id, now createdAt, retryCount 0', () {
      final e = OutboxEntry(payload: 1);
      expect(e.id, isNotEmpty);
      expect(e.retryCount, 0);
      expect(DateTime.now().difference(e.createdAt).inSeconds, lessThan(5));
    });

    group('fromJson with corrupt fields never throws', () {
      test('missing id -> generated non-empty id', () {
        final e = OutboxEntry.fromJson({'payload': {}});
        expect(e.id, isNotEmpty);
      });

      test('empty / non-string id -> generated id', () {
        expect(OutboxEntry.fromJson({'id': '', 'payload': 1}).id, isNotEmpty);
        expect(OutboxEntry.fromJson({'id': 42, 'payload': 1}).id, isNotEmpty);
      });

      test('bad createdAt -> ~now', () {
        for (final bad in ['garbage', 123, null]) {
          final e = OutboxEntry.fromJson({'id': 'a', 'createdAt': bad});
          expect(DateTime.now().difference(e.createdAt).inSeconds, lessThan(5));
        }
      });

      test('retryCount wrong type -> 0', () {
        expect(
            OutboxEntry.fromJson({'id': 'a', 'retryCount': '3'}).retryCount, 0);
        expect(
            OutboxEntry.fromJson({'id': 'a', 'retryCount': 1.5}).retryCount, 0);
      });

      test('is_binary true with non-list payload keeps raw payload', () {
        final e = OutboxEntry.fromJson(
            {'id': 'a', 'is_binary': true, 'payload': 'oops'});
        expect(e.payload, 'oops');
      });

      test('is_binary non-bool is treated as false', () {
        final e = OutboxEntry.fromJson({
          'id': 'a',
          'is_binary': 'true',
          'payload': [1, 2]
        });
        expect(e.payload, isNot(isA<Uint8List>()));
      });

      test('is_binary true with list of non-ints does not throw', () {
        expect(
            () => OutboxEntry.fromJson({
                  'id': 'a',
                  'is_binary': true,
                  'payload': ['x', null]
                }),
            returnsNormally);
      });

      test('empty map', () {
        expect(() => OutboxEntry.fromJson({}), returnsNormally);
      });
    });
  });

  void outboxContract(String name, Outbox Function() create) {
    group('$name contract', () {
      late Outbox outbox;
      setUp(() => outbox = create());

      test('save/getAll returns FIFO by createdAt', () async {
        await outbox.save(OutboxEntry(
            id: 'c', payload: 3, createdAt: DateTime.utc(2024, 1, 3)));
        await outbox.save(OutboxEntry(
            id: 'a', payload: 1, createdAt: DateTime.utc(2024, 1, 1)));
        await outbox.save(OutboxEntry(
            id: 'b', payload: 2, createdAt: DateTime.utc(2024, 1, 2)));
        final all = await outbox.getAll();
        expect(all.map((e) => e.id), ['a', 'b', 'c']);
      });

      test('save same id twice does not duplicate', () async {
        await outbox.save(OutboxEntry(id: 'a', payload: 1));
        await outbox.save(OutboxEntry(id: 'a', payload: 2));
        final all = await outbox.getAll();
        expect(all, hasLength(1));
        expect(all.single.payload, 2);
      });

      test('update changes retryCount', () async {
        final e = OutboxEntry(id: 'a', payload: 1);
        await outbox.save(e);
        await outbox.update(OutboxEntry(
            id: 'a', payload: 1, createdAt: e.createdAt, retryCount: 4));
        expect((await outbox.getAll()).single.retryCount, 4);
      });

      test('update of unknown id does not add it', () async {
        await outbox.update(OutboxEntry(id: 'ghost', payload: 1));
        expect(await outbox.getAll(), isEmpty);
      });

      test('delete removes one entry', () async {
        await outbox.save(OutboxEntry(id: 'a', payload: 1));
        await outbox.save(OutboxEntry(id: 'b', payload: 2));
        await outbox.delete('a');
        await outbox.delete('missing');
        expect((await outbox.getAll()).map((e) => e.id), ['b']);
      });

      test('clear removes all', () async {
        await outbox.save(OutboxEntry(id: 'a', payload: 1));
        await outbox.save(OutboxEntry(id: 'b', payload: 2));
        await outbox.clear();
        expect(await outbox.getAll(), isEmpty);
      });
    });
  }

  outboxContract('InMemoryOutbox', () => InMemoryOutbox());
  outboxContract(
      'PersistentOutbox', () => PersistentOutbox(FakeOutboxStorage()));

  group('PersistentOutbox persistence', () {
    test('data survives a new instance over same storage', () async {
      final storage = FakeOutboxStorage();
      await PersistentOutbox(storage).save(OutboxEntry(
          id: 'a',
          payload: Uint8List.fromList([9, 8]),
          createdAt: DateTime.utc(2024)));
      final all = await PersistentOutbox(storage).getAll();
      expect(all.single.id, 'a');
      expect(all.single.payload, isA<Uint8List>());
      expect(all.single.payload, [9, 8]);
      expect(storage.data['outbox_index'], {
        'ids': ['a']
      });
    });

    test('unreadable entry is skipped, others load, index survives', () async {
      final storage = FakeOutboxStorage();
      final outbox = PersistentOutbox(storage);
      await outbox.save(OutboxEntry(id: 'a', payload: 1));
      await outbox.save(OutboxEntry(id: 'b', payload: 2));
      await outbox.save(OutboxEntry(id: 'c', payload: 3));
      storage.throwOnRead.add('outbox_entry_b');

      final all = await outbox.getAll();
      expect(all.map((e) => e.id).toSet(), {'a', 'c'});
      expect((storage.data['outbox_index']!['ids'] as List), ['a', 'b', 'c']);
    });

    test('entry missing from storage is skipped', () async {
      final storage = FakeOutboxStorage();
      final outbox = PersistentOutbox(storage);
      await outbox.save(OutboxEntry(id: 'a', payload: 1));
      await outbox.save(OutboxEntry(id: 'b', payload: 2));
      storage.data.remove('outbox_entry_a');
      expect((await outbox.getAll()).map((e) => e.id), ['b']);
    });

    test('row with corrupt fields loads tolerantly alongside others', () async {
      final storage = FakeOutboxStorage();
      final outbox = PersistentOutbox(storage);
      await outbox.save(OutboxEntry(id: 'a', payload: 1));
      storage.data['outbox_entry_x'] = {
        'id': 'x',
        'createdAt': 'garbage',
        'retryCount': 'nope',
        'is_binary': true,
        'payload': 'not-a-list',
      };
      storage.data['outbox_index'] = {
        'ids': ['a', 'x']
      };
      final all = await outbox.getAll();
      expect(all.map((e) => e.id).toSet(), {'a', 'x'});
      final x = all.firstWhere((e) => e.id == 'x');
      expect(x.retryCount, 0);
      expect(x.payload, 'not-a-list');
    });

    test('corrupt index yields empty list without throwing', () async {
      final storage = FakeOutboxStorage();
      storage.data['outbox_index'] = {'ids': 'garbage'};
      expect(await PersistentOutbox(storage).getAll(), isEmpty);
      storage.data['outbox_index'] = {
        'ids': [1, 2]
      };
      expect(await PersistentOutbox(storage).getAll(), isEmpty);
    });

    test('entry whose stored id is corrupt can still be deleted', () async {
      final storage = FakeOutboxStorage();
      final outbox = PersistentOutbox(storage);
      storage.data['outbox_entry_k'] = {'payload': 1};
      storage.data['outbox_index'] = {
        'ids': ['k']
      };
      final loaded = (await outbox.getAll()).single;
      await outbox.delete(loaded.id);
      expect(await outbox.getAll(), isEmpty);
    });

    test('clear deletes entry keys and empties index', () async {
      final storage = FakeOutboxStorage();
      final outbox = PersistentOutbox(storage);
      await outbox.save(OutboxEntry(id: 'a', payload: 1));
      await outbox.clear();
      expect(storage.data.containsKey('outbox_entry_a'), isFalse);
      expect(storage.data['outbox_index'], {'ids': []});
    });
  });
}
