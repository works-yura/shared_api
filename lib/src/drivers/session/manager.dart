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
          _cachedState = state;
          await onSave(state);
          _controller.add(state);
          break;
        case UnauthorizedState():
          await clear();
          break;
      }
    });
  }

  @override
  Future<void> clear() async {
    // Note: clear is usually called inside update lock, but we keep it safe
    debugPrint('[ApiSession] Clearing session...');
    _cachedState = null;
    await onDelete();
    // Emit UnauthorizedState with manualLogout reason if explicit clear is called?
    // Or just null? The interface says Stream<State?>. null can mean logged out.
    // However, TokenState.unauthorized is better.
    // But clear() is legacy. Let's make it emit UnauthorizedState.
    _controller
        .add(TokenState.unauthorized(reason: UnauthorizedReason.manualLogout));
  }
}
