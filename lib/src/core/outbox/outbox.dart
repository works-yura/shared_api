export 'entry.dart';
export 'memory.dart';
export 'delegate.dart';

import 'entry.dart';

/// Repository interface for storing pending outbox messages.
///
/// Implementations can use SQLite, Hive, SharedPreferences, or any
/// other persistence mechanism.
abstract class Outbox {
  /// Stores a message in the queue
  Future<void> save(OutboxEntry entry);

  /// Removes a message after receiving ACK
  Future<void> delete(String id);

  /// Returns all pending messages, sorted by creation time
  Future<List<OutboxEntry>> getAll();

  /// Updates retry count for a message
  Future<void> update(OutboxEntry entry);

  /// Clears the entire queue
  Future<void> clear();
}
