import 'dart:isolate';
import 'package:bson/bson.dart' as bson;
import 'codec.dart';

class BsonCodec implements Codec {
  const BsonCodec();

  @override
  String get contentType => 'application/bson';

  @override
  String get protocolName => 'bson';

  @override
  dynamic encode(Map<String, dynamic> data) =>
      bson.BsonCodec.serialize(data).byteList;

  @override
  Future<Map<String, dynamic>> decode(dynamic data) async {
    if (data is! List<int>) return {};

    return await Isolate.run(() {
      final binary = bson.BsonBinary.from(data);
      return bson.BsonCodec.deserialize(binary);
    });
  }
}
