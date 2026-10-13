import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class GzipInterceptor extends Interceptor {
  /// Поріг у байтах, після якого стиснення стає доцільним (напр. 1 КБ)
  final int compressionThreshold;

  GzipInterceptor({this.compressionThreshold = 1024});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // На Web-платформі браузер зазвичай сам керує стисненням, тому пропускаємо
    if (kIsWeb) return handler.next(options);

    final data = options.data;
    if (data == null) return handler.next(options);

    try {
      Uint8List? bytesToCompress;

      // Визначаємо формат даних для стиснення
      if (data is Uint8List) {
        bytesToCompress = data;
      } else if (data is String) {
        bytesToCompress = Uint8List.fromList(utf8.encode(data));
      } else if (data is Map || data is List) {
        // Якщо дані ще не серіалізовані кодеком
        bytesToCompress = Uint8List.fromList(utf8.encode(jsonEncode(data)));
      }

      // Перевіряємо поріг та стискаємо
      if (bytesToCompress != null &&
          bytesToCompress.length > compressionThreshold) {
        options.data = Uint8List.fromList(gzip.encode(bytesToCompress));

        // Додаємо заголовки
        options.headers[HttpHeaders.contentEncodingHeader] = 'gzip';
        // Повідомляємо серверу, що ми також готові прийняти стиснуту відповідь
        options.headers[HttpHeaders.acceptEncodingHeader] = 'gzip';
      }
    } catch (e) {
      // У разі помилки відправляємо оригінальні дані (fail-safe)
    }

    handler.next(options);
  }
}
