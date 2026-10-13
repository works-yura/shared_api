import 'dart:async';
import 'state.dart';

abstract class HttpSession<State extends HttpState> {
  Future<State?> read();
  Future<void> update(State token);
  Future<void> clear();

  /// Stream notifying about session state changes (null = logged out)
  Stream<State?> get status;
}
