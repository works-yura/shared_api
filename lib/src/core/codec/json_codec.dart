import 'dart:convert';
import 'dart:isolate';
import 'codec.dart';

class JsonCodec implements Codec {
  const JsonCodec();

  @override
  String get contentType => 'application/json';

  @override
  String get protocolName => 'json';

  @override
  dynamic encode(Map<String, dynamic> data) => jsonEncode(data);

  @override
  Future<Map<String, dynamic>> decode(dynamic data) async {
    return await Isolate.run(() {
      if (data is Map) return Map<String, dynamic>.from(data);
      if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
      return {};
    });
  }
}
