import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/core/http/method.dart';

void main() {
  test('wire values are upper-case HTTP verbs', () {
    expect(HttpMethod.values.map((m) => m.value), [
      'GET',
      'POST',
      'PATCH',
      'PUT',
      'DELETE',
      'HEAD',
      'OPTIONS',
    ]);
    expect(HttpMethod.post.toString(), 'POST');
  });

  test('when dispatches to matching handler or falls back to other', () {
    expect(HttpMethod.get.when(get: () => 'g', other: () => 'o'), 'g');
    expect(HttpMethod.put.when(get: () => 'g', other: () => 'o'), 'o');
  });
}
