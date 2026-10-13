import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/core/streaming/client.dart';
import 'package:shared_api/src/drivers/http/interceptors/streaming_revival.dart';

class _Streaming implements Streaming {
  _Streaming(this.currentStatus);

  @override
  StreamingStatus currentStatus;
  int attempts = 0;

  @override
  Future<void> connect() async {
    attempts++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.status);
  final int status;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString('{}', status);

  @override
  void close({bool force = false}) {}
}

void main() {
  for (final status in StreamingStatus.values) {
    test('HTTP success does not reset $status socket backoff', () async {
      final streaming = _Streaming(status);
      final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
        ..httpClientAdapter = _Adapter(200)
        ..interceptors.add(StreamingRevivalInterceptor(streaming: streaming));

      await dio.get('/probe');
      expect(
          streaming.attempts, status == StreamingStatus.disconnected ? 1 : 0);
    });

    test('HTTP failure does not reset $status socket backoff', () async {
      final streaming = _Streaming(status);
      final dio = Dio(BaseOptions(baseUrl: 'https://api.test'))
        ..httpClientAdapter = _Adapter(401)
        ..interceptors.add(StreamingRevivalInterceptor(streaming: streaming));

      await expectLater(dio.get('/probe'), throwsA(isA<DioException>()));
      expect(
          streaming.attempts, status == StreamingStatus.disconnected ? 1 : 0);
    });
  }
}
