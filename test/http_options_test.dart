import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';
import 'package:shared_api/src/drivers/http/cancel_token.dart';

void main() {
  test('copyWith keeps extra and cancelToken', () {
    final token = DioCancelToken();
    final original = HttpOptions.post(
      '/items',
      HttpData.json({'a': 1}),
      extra: {'k': 'v'},
    ).copyWith(cancelToken: token);

    final copy = original.copyWith(cachePolicy: HttpCachePolicy.useCache);

    expect(copy.extra, {'k': 'v'});
    expect(copy.cancelToken, same(token));
    expect(copy.cachePolicy, HttpCachePolicy.useCache);
    expect(copy.method, HttpMethod.post);
  });

  test('cachePolicy defaults to noCache', () {
    expect(HttpOptions.get('/x').cachePolicy, HttpCachePolicy.noCache);
  });
}
