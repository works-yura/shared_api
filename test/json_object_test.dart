import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/core/utils/json.dart';

void main() {
  group('JsonObject.as', () {
    const j = JsonObject({
      'i': 5,
      'd': 2.7,
      's': 'hello',
      'b': true,
      'n': null,
      'list': [1, 2],
    });

    test('returns exact type', () {
      expect(j.as<int>('i', 0), 5);
      expect(j.as<double>('d', 0.0), 2.7);
      expect(j.as<String>('s', ''), 'hello');
      expect(j.as<bool>('b', false), isTrue);
    });

    test('coerces int -> double', () {
      final v = j.as<double>('i', 0.0);
      expect(v, 5.0);
      expect(v, isA<double>());
    });

    test('coerces double -> int (truncates)', () {
      expect(j.as<int>('d', 0), 2);
    });

    test('coerces any -> String', () {
      expect(j.as<String>('i', ''), '5');
      expect(j.as<String>('b', ''), 'true');
      expect(j.as<String>('list', ''), '[1, 2]');
    });

    test('nullable T with null default returns exact-typed value', () {
      expect(j.as<int?>('i', null), 5);
      expect(j.as<String?>('s', null), 'hello');
    });

    test('nullable T with non-null default still coerces', () {
      expect(j.as<double?>('i', 0.0), 5.0);
      expect(j.as<int?>('d', 0), 2);
    });

    test('nullable T with null default coerces int -> double', () {
      expect(j.as<double?>('i', null), 5.0);
    });

    test('nullable T missing/wrong type returns null default', () {
      expect(j.as<int?>('missing', null), isNull);
      expect(j.as<int?>('s', null), isNull);
    });

    test('missing key or explicit null returns default', () {
      expect(j.as<int>('missing', 42), 42);
      expect(j.as<String>('n', 'def'), 'def');
    });

    test('wrong type returns default', () {
      expect(j.as<int>('s', -1), -1);
      expect(j.as<bool>('i', false), isFalse);
      expect(j.as<double>('b', 1.5), 1.5);
      expect(j.as<List>('s', const []), isEmpty);
    });
  });

  group('JsonObject.required', () {
    const j = JsonObject({'i': 3, 'd': 3.9, 's': 'x'});

    test('returns present value', () {
      expect(j.required<int>('i'), 3);
      expect(j.required<String>('s'), 'x');
    });

    test('coerces numerics', () {
      expect(j.required<double>('i'), 3.0);
      expect(j.required<int>('d'), 3);
    });

    test('missing key throws JsonDeserializationException', () {
      expect(
        () => j.required<int>('nope'),
        throwsA(isA<JsonDeserializationException>()
            .having((e) => e.key, 'key', 'nope')
            .having((e) => e.expectedType, 'expectedType', int)),
      );
    });

    test('wrong type throws JsonDeserializationException', () {
      expect(
        () => j.required<int>('s'),
        throwsA(isA<JsonDeserializationException>()
            .having((e) => e.value, 'value', 'x')),
      );
      expect(() => j.required<bool>('i'),
          throwsA(isA<JsonDeserializationException>()));
    });

    test('exception toString mentions key and type', () {
      try {
        j.required<int>('s');
        fail('should throw');
      } on JsonDeserializationException catch (e) {
        expect(e.toString(), contains('"s"'));
        expect(e.toString(), contains('int'));
      }
    });
  });

  group('JsonObject.time / timeOrNull', () {
    final fallback = DateTime.utc(2000, 1, 1);
    const j = JsonObject({
      'ok': '2024-05-06T07:08:09.000Z',
      'empty': '',
      'garbage': 'not-a-date',
    });

    test('time parses valid ISO', () {
      expect(j.time('ok'), DateTime.utc(2024, 5, 6, 7, 8, 9));
    });

    test('time returns orElse for missing/empty/garbage', () {
      expect(j.time('missing', orElse: fallback), fallback);
      expect(j.time('empty', orElse: fallback), fallback);
      expect(j.time('garbage', orElse: fallback), fallback);
    });

    test('time without orElse falls back to ~now', () {
      final before = DateTime.now();
      final t = j.time('garbage');
      final after = DateTime.now();
      expect(t.isBefore(before), isFalse);
      expect(t.isAfter(after), isFalse);
    });

    test('timeOrNull', () {
      expect(j.timeOrNull('ok'), DateTime.utc(2024, 5, 6, 7, 8, 9));
      expect(j.timeOrNull('missing'), isNull);
      expect(j.timeOrNull('empty'), isNull);
      expect(j.timeOrNull('garbage'), isNull);
    });
  });

  group('JsonObject helpers', () {
    final j = JsonObject({
      'obj': <String, dynamic>{'a': 1},
      'notObj': 'str',
      'items': [
        <String, dynamic>{'v': 1},
        'skip',
        <String, dynamic>{'v': 2},
        null,
      ],
      'prims': [1, 'a', 2, 3.5, null],
    });

    test('object returns nested or empty', () {
      expect(j.object('obj').as<int>('a', 0), 1);
      expect(j.object('notObj').isEmpty, isTrue);
      expect(j.object('missing').isEmpty, isTrue);
    });

    test('containsKey / isEmpty / isNotEmpty', () {
      expect(j.containsKey('obj'), isTrue);
      expect(j.containsKey('nope'), isFalse);
      expect(j.isEmpty, isFalse);
      expect(j.isNotEmpty, isTrue);
      expect(const JsonObject({}).isEmpty, isTrue);
      expect(const JsonObject({}).isNotEmpty, isFalse);
    });

    test('list maps only map items', () {
      expect(j.list('items', (o) => o.as<int>('v', 0)), [1, 2]);
      expect(j.list('notObj', (o) => 0), isEmpty);
      expect(j.list('missing', (o) => 0), isEmpty);
    });

    test('listAs maps only map items', () {
      expect(j.listAs('items', (m) => m['v']), [1, 2]);
      expect(j.listAs('obj', (m) => m), isEmpty);
    });

    test('primitives filters by type', () {
      expect(j.primitives<int>('prims'), [1, 2]);
      expect(j.primitives<String>('prims'), ['a']);
      expect(j.primitives<int>('missing'), isEmpty);
    });

    test('map maps nested object or null', () {
      expect(j.map('obj', (m) => m['a']), 1);
      expect(j.map('notObj', (m) => m), isNull);
    });

    test('toMap is unmodifiable', () {
      expect(() => j.toMap()['x'] = 1, throwsUnsupportedError);
    });

    test('fromString handles object, array and garbage', () {
      expect(JsonObject.fromString('{"a":1}').as<int>('a', 0), 1);
      expect(JsonObject.fromString('[1,2]').isEmpty, isTrue);
      expect(JsonObject.fromString('{bad').isEmpty, isTrue);
    });

    test('Map.json extension', () {
      expect(<String, dynamic>{'k': 'v'}.json.as<String>('k', ''), 'v');
    });
  });
}
