import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';

void main() {
  const schema = {'minLength': 3, 'maxLength': 5, 'pattern': r'^[a-z]+$'};

  test('valid value passes', () {
    expect(ValidationEngine.validate('abcd', schema), isNull);
  });

  test('default English fallbacks', () {
    expect(ValidationEngine.validate('', schema), 'Field is required');
    expect(ValidationEngine.validate('ab', schema), 'Too short');
    expect(ValidationEngine.validate('abcdef', schema), 'Too long');
    expect(ValidationEngine.validate('ab1', schema), 'Invalid format');
  });

  test('custom messages override fallbacks', () {
    expect(
      ValidationEngine.validate('ab', schema,
          messages: {'tooShort': 'Закоротко'}),
      'Закоротко',
    );
  });

  test('schema errorMessages and description win over fallbacks', () {
    expect(
      ValidationEngine.validate('ab', {
        ...schema,
        'errorMessages': {'minLength': 'min 3'},
      }),
      'min 3',
    );
    expect(
      ValidationEngine.validate('AB1', {...schema, 'description': 'lowercase'}),
      'lowercase',
    );
  });

  test('malformed schema values are ignored instead of throwing', () {
    expect(
      ValidationEngine.validate('x', {'minLength': '3', 'errorMessages': 'x'}),
      isNull,
    );
  });
}
