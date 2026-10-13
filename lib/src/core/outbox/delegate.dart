import 'outbox.dart';

/// Callback-based adapter for [Outbox].
///
/// Allows delegating persistence logic to external functions,
/// enabling integration with any storage mechanism (Hive, SQLite, etc.)
/// without creating a full implementation class.
///
class OnOutbox implements Outbox {
  final Future<void> Function(OutboxEntry entry) onSave;
  final Future<void> Function(String id) onDelete;
  final Future<List<OutboxEntry>> Function() onGetAll;
  final Future<void> Function(OutboxEntry entry) onUpdate;
  final Future<void> Function() onClear;

  OnOutbox({
    required this.onSave,
    required this.onDelete,
    required this.onGetAll,
    required this.onUpdate,
    required this.onClear,
  });

  @override
  Future<void> save(OutboxEntry entry) => onSave(entry);

  @override
  Future<void> delete(String id) => onDelete(id);

  @override
  Future<List<OutboxEntry>> getAll() => onGetAll();

  @override
  Future<void> update(OutboxEntry entry) => onUpdate(entry);

  @override
  Future<void> clear() => onClear();
}
