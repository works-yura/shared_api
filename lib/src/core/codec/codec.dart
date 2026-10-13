export 'json_codec.dart';
export 'bson_codec.dart';

/// Базовий інтерфейс для кодування/декодування даних API (HTTP та WebSocket)
abstract interface class Codec {
  /// MIME-тип для заголовків Content-Type та Accept
  String get contentType;

  /// Назва протоколу для WebSocket Subprotocol Negotiation
  String get protocolName;

  /// Кодує Map у формат для відправки (String або Uint8List)
  dynamic encode(Map<String, dynamic> data);

  /// Декодує отримані дані у Map
  Future<Map<String, dynamic>> decode(dynamic data);
}
