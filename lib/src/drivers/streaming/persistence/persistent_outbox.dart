import '/src/core/core.dart';

/// Minimal key-value storage contract used by [PersistentOutbox].
///
/// Back it with SharedPreferences, Hive, files, secure storage, etc.
abstract class OutboxStorage {
  Future<Map<String, dynamic>?> read(String key);

  Future<void> write(String key, Map<String, dynamic> value);

  Future<void> delete(String key);
}

/// Implementation of [Outbox] that uses [OutboxStorage] for persistence.
///
/// This ensures that messages survive app restarts and crashes.
class PersistentOutbox implements Outbox {
  final OutboxStorage _storage;

  /// Key for storing the list of pending message IDs
  static const _indexKey = 'outbox_index';

  PersistentOutbox(this._storage);

  @override
  Future<void> save(OutboxEntry entry) async {
    // 1. Save entry data
    await _storage.write(_entryKey(entry.id), entry.toJson());

    // 2. Update index
    final index = await _getIndex();
    if (!index.contains(entry.id)) {
      index.add(entry.id);
      await _saveIndex(index);
    }
  }

  @override
  Future<void> delete(String id) async {
    // 1. Remove entry data
    await _storage.delete(_entryKey(id));

    // 2. Remove from index
    final index = await _getIndex();
    if (index.remove(id)) {
      await _saveIndex(index);
    }
  }

  @override
  Future<List<OutboxEntry>> getAll() async {
    final index = await _getIndex();
    final entries = <OutboxEntry>[];

    for (final id in index) {
      try {
        final json = await _storage.read(_entryKey(id));
        if (json != null) {
          entries.add(OutboxEntry.fromJson(json));
        }
      } catch (_) {
        // Ignore if missing or corrupted
      }
    }

    // Sort by creation time to preserve FIFO order
    entries.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return entries;
  }

  @override
  Future<void> update(OutboxEntry entry) async {
    await _storage.write(_entryKey(entry.id), entry.toJson());
  }

  @override
  Future<void> clear() async {
    final index = await _getIndex();
    for (final id in index) {
      await _storage.delete(_entryKey(id));
    }
    await _saveIndex([]);
  }

  // ==========================================================================
  // Helpers
  // ==========================================================================

  String _entryKey(String id) => 'outbox_entry_$id';

  Future<List<String>> _getIndex() async {
    try {
      final json = await _storage.read(_indexKey);
      if (json == null) return [];
      return List<String>.from(json['ids'] as Iterable);
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveIndex(List<String> ids) async {
    await _storage.write(_indexKey, {'ids': ids});
  }
}
