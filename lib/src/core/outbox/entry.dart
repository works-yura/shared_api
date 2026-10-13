import 'dart:typed_data';
import 'package:shared_api/src/core/utils/device_id.dart';

/// Entry representing a pending WebSocket message in the outbox queue.
///
/// Contains metadata needed for retry logic and idempotency.
class OutboxEntry {
  /// Unique message identifier (UUID-like)
  final String id;

  /// Serialized message payload (can be Map for JSON or Uint8List for BSON)
  final dynamic payload;

  /// When the entry was created
  final DateTime createdAt;

  /// Number of retry attempts
  int retryCount;

  OutboxEntry({
    String? id,
    required this.payload,
    DateTime? createdAt,
    this.retryCount = 0,
  })  : id = id ?? DeviceId.generate(16),
        createdAt = createdAt ?? DateTime.now();

  /// Serializes entry for external storage
  Map<String, dynamic> toJson() => {
        'id': id,
        'payload':
            payload is Uint8List ? (payload as Uint8List).toList() : payload,
        'createdAt': createdAt.toIso8601String(),
        'retryCount': retryCount,
        'is_binary': payload is Uint8List,
      };

  /// Deserializes entry from external storage
  factory OutboxEntry.fromJson(Map<String, dynamic> json) {
    // Tolerant parsing: one corrupt persisted row must not break outbox loading.
    final isBinaryRaw = json['is_binary'];
    final isBinary = isBinaryRaw is bool && isBinaryRaw;
    final rawPayload = json['payload'];
    final idRaw = json['id'];
    final createdRaw = json['createdAt'];
    final retryRaw = json['retryCount'];

    return OutboxEntry(
      id: idRaw is String && idRaw.isNotEmpty ? idRaw : null,
      payload: isBinary && rawPayload is List
          ? Uint8List.fromList(List<int>.from(rawPayload))
          : rawPayload,
      createdAt: createdRaw is String ? DateTime.tryParse(createdRaw) : null,
      retryCount: retryRaw is int ? retryRaw : 0,
    );
  }
}
