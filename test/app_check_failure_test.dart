import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

void main() {
  for (final (code, kind, status) in [
    ('APP_CHECK_FAILED', AppCheckFailureKind.rejected, 403),
    ('APP_CHECK_UNAVAILABLE', AppCheckFailureKind.unavailable, 503),
  ]) {
    test('HTTP $status $code becomes a global App Check failure', () {
      final exception = HttpException.response(
        status: status,
        message: 'Localized server message',
        data: {'errorCode': code},
        headers: const {},
      );
      final failure = exception.toFailure();
      expect(failure, isA<AppCheckFailure>());
      expect((failure as AppCheckFailure).kind, kind);
      expect(failure.message, 'Localized server message');
    });
  }

  test('ordinary HTTP errors keep their existing mapping', () {
    final exception = HttpException.response(
      status: 403,
      message: 'Forbidden',
      data: {'errorCode': 'OTHER_CODE'},
      headers: const {},
    );
    expect(exception.toFailure(), isA<ForbiddenFailure>());
  });
}
