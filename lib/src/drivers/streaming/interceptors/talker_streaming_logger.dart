import 'package:talker/talker.dart';
import '/src/core/core.dart';

/// Implementation of [StreamingInterceptor] that uses [Talker] for logging.
class TalkerStreamingLogger extends StreamingInterceptor {
  final Talker _talker;

  TalkerStreamingLogger({Talker? talker}) : _talker = talker ?? Talker();

  @override
  void onRequest(StreamingOptions options) {
    _talker.log(
      'WS >> SEND: ${options.action}',
      pen: AnsiPen()..green(),
    );
    if (options.data.isNotEmpty) {
      _talker.verbose('WS DATA: ${options.data}');
    }
  }

  @override
  void onResponse(StreamingResponse response) {
    _talker.log(
      'WS << RECV: ${response.type ?? 'EVENT'}',
      pen: AnsiPen()..blue(),
    );
    _talker.verbose('WS DATA: ${response.data}');
  }

  @override
  void onError(Object error, [StackTrace? stackTrace]) {
    _talker.handle(error, stackTrace, 'WS !! ERROR');
  }

  @override
  void onStatusChanged(StreamingStatus status) {
    _talker.info('WS [ STATUS ] -> ${status.name.toUpperCase()}');
  }
}
