import 'outbox.dart';

/// In-memory implementation of [OutboxRepository].
///
/// Useful for testing and development. Does not persist across app restarts.
class InMemoryOutbox implements Outbox {
  final Map<String, OutboxEntry> _storage = {};

  @override
  Future<void> save(OutboxEntry entry) async {
    _storage[entry.id] = entry;
  }

  @override
  Future<void> delete(String id) async {
    _storage.remove(id);
  }

  @override
  Future<List<OutboxEntry>> getAll() async {
    final list = _storage.values.toList();
    // Sort by creation time to preserve FIFO order
    list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return list;
  }

  @override
  Future<void> update(OutboxEntry entry) async {
    if (_storage.containsKey(entry.id)) {
      _storage[entry.id] = entry;
    }
  }

  @override
  Future<void> clear() async {
    _storage.clear();
  }
}
