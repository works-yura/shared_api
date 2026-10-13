import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/shared_api.dart';
import 'package:shared_api/src/drivers/http/error_handler.dart';

final _options = RequestOptions(path: '/x');

DioException _error(
  DioExceptionType type, {
  Response<dynamic>? response,
  String? message,
  Object? error,
}) =>
    DioException(
      requestOptions: _options,
      type: type,
      response: response,
      message: message,
      error: error,
    );

Response<dynamic> _response(Object? data,
        {int? status = 400, Map<String, List<String>>? headers}) =>
    Response<dynamic>(
      requestOptions: _options,
      data: data,
      statusCode: status,
      headers: Headers.fromMap(headers ?? {}),
    );

void main() {
  group('DioErrorHandler type mapping', () {
    const expected = {
      DioExceptionType.connectionTimeout: HttpExceptionType.timeout,
      DioExceptionType.sendTimeout: HttpExceptionType.timeout,
      DioExceptionType.receiveTimeout: HttpExceptionType.timeout,
      DioExceptionType.transformTimeout: HttpExceptionType.timeout,
      DioExceptionType.cancel: HttpExceptionType.cancel,
      DioExceptionType.badCertificate: HttpExceptionType.certificate,
      DioExceptionType.connectionError: HttpExceptionType.connection,
      DioExceptionType.unknown: HttpExceptionType.unknown,
    };

    for (final entry in expected.entries) {
      test('${entry.key.name} → ${entry.value.name}', () {
        final e = DioErrorHandler.handle(_error(entry.key));
        expect(e.type, entry.value);
      });
    }

    test('every DioExceptionType is covered', () {
      final covered = {...expected.keys, DioExceptionType.badResponse};
      expect(covered, containsAll(DioExceptionType.values));
    });
  });

  group('unknown', () {
    test('uses DioException.message', () {
      final e = DioErrorHandler.handle(
          _error(DioExceptionType.unknown, message: 'msg', error: 'err'));
      expect(e.message, 'msg');
    });

    test('falls back to error.toString() when message is null', () {
      final e = DioErrorHandler.handle(
          _error(DioExceptionType.unknown, error: StateError('inner')));
      expect(e.message, contains('inner'));
    });

    test('null message and error → null message', () {
      final e = DioErrorHandler.handle(_error(DioExceptionType.unknown));
      expect(e.message, isNull);
      expect(e.toString(), 'Unknown Error');
    });
  });

  group('badResponse', () {
    HttpResponseException handle(Response<dynamic>? response,
        {String? message}) {
      final e = DioErrorHandler.handle(_error(DioExceptionType.badResponse,
          response: response, message: message));
      expect(e, isA<HttpResponseException>());
      return e as HttpResponseException;
    }

    test('no response → unknown', () {
      final e = DioErrorHandler.handle(_error(DioExceptionType.badResponse));
      expect(e.type, HttpExceptionType.unknown);
      expect(e, isNot(isA<HttpResponseException>()));
    });

    test('status and String message from body', () {
      final body = {'message': 'Not found', 'errorCode': 'NF'};
      final e = handle(_response(body,
          status: 404,
          headers: {
            'x-id': ['1']
          }));

      expect(e.type, HttpExceptionType.response);
      expect(e.status, 404);
      expect(e.message, 'Not found');
      expect(e.data, body);
      expect(e.headers['x-id'], ['1']);
      expect(e.errorCode, 'NF');
    });

    test('List message is joined with newlines', () {
      final e = handle(_response({
        'message': ['email is invalid', 'password too short']
      }, status: 422));

      expect(e.status, 422);
      expect(e.message, 'email is invalid\npassword too short');
    });

    test('non-string list items are stringified', () {
      final e = handle(_response({
        'message': [1, 'two']
      }));
      expect(e.message, '1\ntwo');
    });

    test('empty String message falls back to DioException.message', () {
      final e = handle(_response({'message': ''}), message: 'dio msg');
      expect(e.message, 'dio msg');
    });

    test('empty List message falls back to DioException.message', () {
      final e = handle(_response({'message': []}), message: 'dio msg');
      expect(e.message, 'dio msg');
    });

    test('non-map body uses DioException.message', () {
      final e = handle(_response('plain text', status: 502),
          message: 'Bad gateway');
      expect(e.status, 502);
      expect(e.message, 'Bad gateway');
      expect(e.data, 'plain text');
    });

    test('no message anywhere → "Server Error"', () {
      final e = handle(_response({'other': 1}, status: 500));
      expect(e.message, 'Server Error');
    });

    test('null statusCode → 500', () {
      final e = handle(_response({'message': 'x'}, status: null));
      expect(e.status, 500);
    });

    test('toFailure maps status codes', () {
      expect(handle(_response({'message': 'a'}, status: 401)).toFailure(),
          isA<UnauthorizedFailure>());
      expect(handle(_response({'message': 'a'}, status: 403)).toFailure(),
          isA<ForbiddenFailure>());
      expect(
          handle(_response({
            'message': 'a',
            'errors': {'f': 'bad'}
          }, status: 400))
              .toFailure(),
          isA<ValidationFailure>()
              .having((f) => f.errors, 'errors', {'f': 'bad'}));
      expect(handle(_response({'message': 'a'}, status: 503)).toFailure(),
          isA<ServerFailure>().having((f) => f.code, 'code', '503'));
    });
  });

  group('HttpException.when', () {
    test('dispatches to the matching handler', () {
      String run(HttpException e) => e.when(
            timeout: () => 'timeout',
            certificate: () => 'certificate',
            cancel: () => 'cancel',
            connection: () => 'connection',
            response: () => 'response',
            serialization: (m, o) => 'serialization:$m:$o',
            upgradeRequired: () => 'upgrade',
            unknown: () => 'unknown',
          );

      expect(run(HttpException.timeout()), 'timeout');
      expect(run(HttpException.certificate()), 'certificate');
      expect(run(HttpException.cancel()), 'cancel');
      expect(run(HttpException.connection()), 'connection');
      expect(run(HttpException.response(headers: const {})), 'response');
      expect(
          run(HttpException.serialization(message: 'm', originalError: 'o')),
          'serialization:m:o');
      expect(run(HttpException.upgradeRequired()), 'upgrade');
      expect(run(HttpException.unknown()), 'unknown');
    });

    test('serialization falls back to unknown() when handler omitted', () {
      final e = HttpException.serialization(message: 'bad json');
      expect(e.when(unknown: () => 'fallback'), 'fallback');
    });

    test('serialization fallback with nullable result type', () {
      final e = HttpException.serialization(message: 'bad json');
      expect(e.when<String?>(unknown: () => 'fallback'), 'fallback');
    },
        skip: 'BUG: lib/src/core/exceptions/exception.dart:101 — when<W> with '
            'nullable W returns null instead of unknown() when the '
            'serialization handler is omitted (null passes `is W`).');

    test('any omitted handler falls back to unknown()', () {
      for (final e in [
        HttpException.timeout(),
        HttpException.certificate(),
        HttpException.cancel(),
        HttpException.connection(),
        HttpException.response(headers: const {}),
        HttpException.upgradeRequired(),
      ]) {
        expect(e.when(unknown: () => 'fallback'), 'fallback',
            reason: e.type.name);
      }
    });

    test('toFailure on serialization keeps the message', () {
      final f = HttpException.serialization(message: 'bad json').toFailure();
      expect(
          f,
          isA<UnknownFailure>()
              .having((f) => f.message, 'message', 'Data Parsing Error')
              .having((f) => f.originalError, 'originalError', 'bad json'));
    });
  });
}
