import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/core/http/method.dart';
import 'package:shared_api/src/drivers/session/state.dart';
import 'package:shared_api/src/data/requests/requests.dart';
import 'package:shared_api/src/data/responses/responses.dart';
import 'package:shared_api/src/data/shared/types.dart';

class _IntRequest extends BaseRequest<int> {
  _IntRequest() : super('/int');

  @override
  HttpOptions onRequest(ApiCredentials credentials) => HttpOptions.get(path);
}

class _NamesRequest extends JsonArrayRequest<String> {
  _NamesRequest() : super('/names');

  @override
  HttpOptions onRequest(ApiCredentials credentials) => HttpOptions.get(path);

  @override
  String mapItem(JsonObject json, HttpResponse response) =>
      json.as<String>('name', '?');
}

HttpResponse _resp(dynamic data) =>
    HttpResponse(status: 200, headers: const {}, data: data);

const _creds =
    ApiCredentials(host: 'example.com', clientID: 'id', clientSecret: 's');

void main() {
  group('HttpRequest.onResponse default', () {
    test('matching type returns data', () {
      expect(_IntRequest().onResponse(_resp(7)), 7);
    });

    test('mismatch throws StateError naming both types', () {
      expect(
        () => _IntRequest().onResponse(_resp('seven')),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('int'))
            .having((e) => e.message, 'message', contains('String'))),
      );
    });

    test('default onSession is null', () {
      expect(_IntRequest().onSession(1), isNull);
    });
  });

  group('JsonArrayRequest', () {
    test('maps list of maps via mapItem', () {
      final r = _NamesRequest().onResponse(_resp([
        <String, dynamic>{'name': 'a'},
        <String, dynamic>{'name': 'b'},
      ]));
      expect(r, ['a', 'b']);
    });

    test('skips non-map items', () {
      final r = _NamesRequest().onResponse(_resp([
        <String, dynamic>{'name': 'a'},
        1,
        'str',
        null,
        [1],
        <String, dynamic>{},
      ]));
      expect(r, ['a', '?']);
    });

    test('non-list body -> empty list', () {
      expect(_NamesRequest().onResponse(_resp({'name': 'a'})), isEmpty);
      expect(_NamesRequest().onResponse(_resp(null)), isEmpty);
      expect(_NamesRequest().onResponse(_resp('[]')), isEmpty);
    });
  });

  group('Example requests', () {
    test('ExampleGetListRequest defaults and custom page/limit', () {
      final d = ExampleGetListRequest().onRequest(_creds);
      expect(d.method, HttpMethod.get);
      expect(d.path, '/api/v1/examples');
      expect(d.queries, {'page': 1, 'limit': 20});
      expect(d.data, isNull);

      final c = ExampleGetListRequest(page: 3, limit: 5).onRequest(_creds);
      expect(c.queries, {'page': 3, 'limit': 5});
    });

    test('ExampleGetListRequest maps response items', () {
      final list = ExampleGetListRequest().onResponse(_resp([
        <String, dynamic>{'id': '1', 'title': 't', 'completed': true},
        'junk',
      ]));
      expect(list, hasLength(1));
      expect(list.single.id, '1');
      expect(list.single.title, 't');
      expect(list.single.completed, isTrue);
    });

    test('ExampleGetOneRequest path', () {
      final o = ExampleGetOneRequest(id: '42').onRequest(_creds);
      expect(o.method, HttpMethod.get);
      expect(o.path, '/api/v1/examples/42');
    });

    test('ExampleCreateRequest body and response', () {
      final req = ExampleCreateRequest(title: 'Hello');
      final o = req.onRequest(_creds);
      expect(o.method, HttpMethod.post);
      expect(o.path, '/api/v1/examples');
      expect(o.data!.isJson(), isTrue);
      expect(o.data!.data, {'title': 'Hello'});

      final r = req.onResponse(_resp(<String, dynamic>{
        'id': 'x',
        'title': 'Hello',
        'completed': false,
      }));
      expect(r.toJson(), {'id': 'x', 'title': 'Hello', 'completed': false});
    });

    test('ExampleDeleteRequest', () {
      final o = ExampleDeleteRequest(id: 'abc').onRequest(_creds);
      expect(o.method, HttpMethod.delete);
      expect(o.path, '/api/v1/examples/abc');
      expect(o.data!.data, isEmpty);
    });

    test('AuthSignInRequest body', () {
      final o = AuthSignInRequest(email: 'a@b.c', password: 'pw')
          .onRequest(_creds);
      expect(o.method, HttpMethod.post);
      expect(o.path, '/api/v1/auth/sign-in');
      expect(o.data!.isJson(), isTrue);
      expect(o.data!.data, {'email': 'a@b.c', 'password': 'pw'});
    });

    test('AuthSignInRequest onResponse + onSession -> AuthorizedState', () {
      final req = AuthSignInRequest(email: 'a', password: 'b');
      final tokens = req.onResponse(_resp(<String, dynamic>{
        'accessToken': 'acc',
        'refreshToken': 'ref',
        'expires_in': 900,
      }));
      expect(tokens.expiresIn, 900);

      final before = DateTime.now();
      final state = req.onSession(tokens);
      expect(state, isA<AuthorizedState>());
      final auth = state as AuthorizedState;
      expect(auth.access, 'acc');
      expect(auth.refresh, 'ref');
      expect(auth.expiresIn, 900);
      expect(auth.createdAt.isBefore(before), isFalse);
    });

    test('TokensResponse prefers camelCase expiresIn', () {
      final t = TokensResponse.fromJson(const JsonObject(
          {'accessToken': 'a', 'expiresIn': 60, 'expires_in': 900}));
      expect(t.expiresIn, 60);
      expect(t.refreshToken, '');
    });

    test('AuthRefreshRequest body and session', () {
      final req = AuthRefreshRequest(refreshToken: 'rt');
      final o = req.onRequest(_creds);
      expect(o.method, HttpMethod.post);
      expect(o.path, '/api/v1/auth/refresh');
      expect(o.data!.data, {'refreshToken': 'rt'});
      expect(req.token, 'rt');

      final state = req.onSession(TokensResponse(
          accessToken: 'a2', refreshToken: 'r2', expiresIn: 30));
      expect(state, isA<AuthorizedState>());
      expect((state as AuthorizedState).access, 'a2');
    });

    test('AuthSignOutRequest', () {
      final o = AuthSignOutRequest().onRequest(_creds);
      expect(o.method, HttpMethod.post);
      expect(o.path, '/api/v1/auth/sign-out');
      expect(o.data!.data, isEmpty);
    });
  });
}
