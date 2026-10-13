import 'dart:async';
import 'state.dart';
import 'interface.dart';

class HttpOnSession<State extends HttpState> implements HttpSession<State> {
  final Future<void> Function(State state) onUpdate;
  final Future<void> Function() onClear;
  final Future<State?> Function() onRead;
  final Stream<State?> onStatus;

  HttpOnSession({
    required this.onRead,
    required this.onUpdate,
    required this.onClear,
    required this.onStatus,
  });

  @override
  Stream<State?> get status => onStatus;

  @override
  Future<void> clear() {
    return onClear();
  }

  @override
  Future<State?> read() {
    return onRead();
  }

  @override
  Future<void> update(State state) {
    return onUpdate(state);
  }
}
