import 'dart:async';
import 'state.dart';
import 'interface.dart';

class InMemoryHttpSession<State extends HttpState>
    implements HttpSession<State> {
  State? _state;
  final _controller = StreamController<State?>.broadcast();

  @override
  Future<State?> read() async {
    return _state;
  }

  @override
  Future<void> update(State state) async {
    _state = state;
    _controller.add(state);
  }

  @override
  Future<void> clear() async {
    _state = null;
    _controller.add(null);
  }

  @override
  Stream<State?> get status => _controller.stream;
}
