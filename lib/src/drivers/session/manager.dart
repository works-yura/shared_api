import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import '../../core/core.dart';
import 'state.dart';

class SharedApiSession extends ApiSession {
  SharedApiSession({
    required super.onSave,
    required super.onDelete,
    required super.onLoad,
  });
}

class ApiSession extends HttpSession<TokenState> {
  final _controller = StreamController<TokenState?>.broadcast();
  TokenState? _cachedState;
  final _lock = Lock();

  final Future<void> Function(TokenState state) onSave;
  final Future<void> Function() onDelete;
  final Future<TokenState?> Function() onLoad;

  ApiSession({
    required this.onSave,
    required this.onDelete,
    required this.onLoad,
  });

  @override
  Stream<TokenState?> get status => _controller.stream;

  @override
  Future<TokenState?> read() async {
    return _lock.synchronized(() async {
      if (_cachedState != null) {
        return _cachedState;
      }

      debugPrint('[ApiSession] Loading state from storage...');
      final state = await onLoad();

      // IMPORTANT: If _cachedState was updated while we were loading from storage,
      // we MUST NOT overwrite it with potentially stale data from onLoad().
      if (_cachedState == null) {
        _cachedState = state;
        debugPrint('[ApiSession] Loaded state: ${state?.runtimeType}');
        _controller.add(_cachedState);
      } else {
        debugPrint(
            '[ApiSession] read() finished, but _cachedState was already set to ${_cachedState.runtimeType}. Skipping overwrite.');
      }

      return _cachedState;
    });
  }

  @override
  Future<void> update(TokenState state) async {
    await _lock.synchronized(() async {
      debugPrint('[ApiSession] Updating state: ${state.runtimeType}');

      switch (state) {
        case AuthorizedState():
          // Persist first: never cache a state that failed to save.
          await onSave(state);
          _cachedState = state;
          _controller.add(state);
          break;
        case UnauthorizedState():
          await _clear(state.reason);
          break;
      }
    });
  }

  @override
  Future<void> clear() => _clear(UnauthorizedReason.manualLogout);

  /// Drops the cached state and storage, then emits [UnauthorizedState] with
  /// [reason] so listeners can tell an expired session from a manual logout.
  Future<void> _clear(UnauthorizedReason reason) async {
    debugPrint('[ApiSession] Clearing session ($reason)...');
    _cachedState = null;
    await onDelete();
    _controller.add(TokenState.unauthorized(reason: reason));
  }
}
