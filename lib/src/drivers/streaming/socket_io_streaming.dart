import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as io;
import '/src/core/core.dart';
import '/src/drivers/http/interceptors/app_check.dart';
import '/src/drivers/session/state.dart';

/// Socket.IO implementation of [Streaming].
///
/// Connection lifecycle is owned by an explicit state machine, not derived
/// from `socket.active` — that flag lies during teardown. Each socket attempt
/// has a `_generation` tag captured by its listeners so events from a
/// torn-down socket are dropped instead of bleeding into the next attempt.
class SocketIOStreaming<S extends HttpState, C extends HttpCredentials>
    implements Streaming {
  final C credentials;
  final HttpSession<S>? session;
  final RetryConfig retryConfig;

  /// Firebase App Check token for the handshake (`auth.appCheck`), checked by
  /// the server once per connection — every reconnect fetches it again.
  final Future<String?> Function()? appCheckToken;
  final io.Socket Function(String url, Map<String, dynamic> options)
      _createSocket;

  @override
  final List<StreamingInterceptor> interceptors;

  io.Socket? _socket;
  int _generation = 0;
  bool _disposed = false;
  String? _rejectedAccessToken;

  StreamingStatus _status = StreamingStatus.disconnected;
  DateTime? _connectingSince;

  final _statusController = StreamController<StreamingStatus>.broadcast();

  final Set<StreamingRequest> _persistentRequests = {};
  final Map<String, List<void Function(dynamic)>> _activeListeners = {};

  // Reconnect: single timer, exponential backoff, hard cap.
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 8;
  static const Duration _baseReconnectDelay = Duration(seconds: 1);
  static const Duration _maxReconnectDelay = Duration(seconds: 30);

  // Watchdog — engine.io can hang the handshake without firing any event
  // (TCP RST swallowed, transport upgrade stuck). Force teardown if we don't
  // reach `connected` in time.
  Timer? _connectWatchdog;
  static const Duration _connectTimeout = Duration(seconds: 10);

  // Microtask burst guard. Token refresh + lifecycle resume + connectivity
  // restored can all fire connect() in the same tick.
  DateTime? _lastConnectAttempt;
  static const Duration _connectCooldown = Duration(milliseconds: 500);

  SocketIOStreaming({
    required this.credentials,
    this.session,
    this.interceptors = const [],
    this.retryConfig = const RetryConfig(),
    this.appCheckToken,
    io.Socket Function(String url, Map<String, dynamic> options)? createSocket,
  }) : _createSocket = createSocket ?? io.io;

  /// Handshake payload: the access token plus, when available, App Check.
  static Map<String, dynamic> handshakeAuth(String? token, String? appCheck) =>
      {'token': token, if (appCheck != null) 'appCheck': appCheck};

  @override
  dynamic prepare(Map<String, dynamic> data) => data;

  @override
  Stream<StreamingStatus> get status => _statusController.stream;

  @override
  StreamingStatus get currentStatus => _status;

  @override
  bool get isConnected => _status == StreamingStatus.connected;

  /// True if the current connect attempt has been in progress past the
  /// watchdog timeout. HTTP revival uses this to detect zombie sockets.
  bool get isStuckConnecting {
    if (_status != StreamingStatus.connecting &&
        _status != StreamingStatus.reconnecting) {
      return false;
    }
    final since = _connectingSince;
    if (since == null) return false;
    return DateTime.now().difference(since) > _connectTimeout;
  }

  void _setStatus(StreamingStatus next) {
    if (_status == next) return;
    _status = next;
    if (next == StreamingStatus.connecting ||
        next == StreamingStatus.reconnecting) {
      _connectingSince ??= DateTime.now();
    } else {
      _connectingSince = null;
    }
    _statusController.add(next);
    for (final i in interceptors) i.onStatusChanged(next);
  }

  @override
  Future<void> connect() async {
    if (_disposed) return;
    if (_status == StreamingStatus.connected) return;

    final now = DateTime.now();
    if (_lastConnectAttempt != null &&
        now.difference(_lastConnectAttempt!) < _connectCooldown) {
      return;
    }
    _lastConnectAttempt = now;

    // Healthy attempt already in flight — don't fight the watchdog.
    if (_status == StreamingStatus.connecting && !isStuckConnecting) {
      return;
    }

    // External entry: take over any pending backoff cycle and stuck socket.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _teardown();
    await _open();
  }

  Future<void> _open() async {
    if (_disposed) return;
    final myGen = ++_generation;
    S? state;
    try {
      state = await session?.read();
    } catch (_) {}
    if (_disposed || myGen != _generation) return;

    // HTTP activity and app resume also request a socket connection. During
    // sign-up there is no access token, so opening one would cause the server
    // to reject `auth` and each brief connection to refresh protected badges.
    if (state is! AuthorizedState || state.access.trim().isEmpty) {
      _lastConnectAttempt = null; // A subsequent login may connect immediately.
      _setStatus(StreamingStatus.disconnected);
      return;
    }
    if (state.access == _rejectedAccessToken) {
      _setStatus(StreamingStatus.disconnected);
      return;
    }

    _setStatus(StreamingStatus.connecting);

    final appCheck =
        appCheckToken == null ? null : await tryAppCheckToken(appCheckToken!);

    if (_disposed || myGen != _generation) return;

    final url = _buildUrl();

    // forceNew bypasses the package-global Manager cache. The cache hands back
    // partially torn-down managers after rapid disconnect/connect cycles
    // (token refresh path), which produces phantom "disconnect" emissions.
    final socket = _createSocket(
      url,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setPath('/ws')
          .setAuth(handshakeAuth(state.access, appCheck))
          .disableAutoConnect()
          .disableReconnection()
          .enableForceNew()
          .build(),
    );

    _socket = socket;
    _bindListeners(socket, myGen, state.access);
    _applyActiveListeners(socket);

    _connectWatchdog?.cancel();
    _connectWatchdog = Timer(_connectTimeout, () {
      if (_disposed || myGen != _generation) return;
      if (_status == StreamingStatus.connected) return;
      _teardown();
      _scheduleReconnect();
    });

    socket.connect();
  }

  void _bindListeners(io.Socket s, int gen, String accessToken) {
    s.onConnect((_) {
      if (_disposed || gen != _generation) return;
      // A transport connection is not an authenticated app session yet.
      // The gateway answers `auth` with `authenticated` only after its JWT
      // guard succeeds. Publishing connected earlier refreshed protected
      // badges before the server had accepted the identity.
      s.emit('auth');
    });

    s.on('authenticated', (_) {
      if (_disposed || gen != _generation) return;
      _rejectedAccessToken = null;
      _connectWatchdog?.cancel();
      _connectWatchdog = null;
      _reconnectAttempts = 0;
      _setStatus(StreamingStatus.connected);
      _flushPersistentRequests();
    });

    s.on('exception', (_) {
      if (_disposed || gen != _generation) return;
      if (_status != StreamingStatus.connecting) return;
      // The server rejected `auth`. HTTP activity must not retry the same
      // token indefinitely; a new session token can start a fresh attempt.
      _rejectedAccessToken = accessToken;
      _teardown();
      _setStatus(StreamingStatus.disconnected);
    });

    s.onDisconnect((_) {
      if (_disposed || gen != _generation) return;
      _setStatus(StreamingStatus.reconnecting);
      _scheduleReconnect();
    });

    s.onConnectError((err) {
      if (_disposed || gen != _generation) return;
      for (final i in interceptors) i.onError(err);
      _setStatus(StreamingStatus.reconnecting);
      _scheduleReconnect();
    });
  }

  /// Tear down the current socket without scheduling reconnect. Generation is
  /// bumped FIRST so any in-flight async event fires its `gen != _generation`
  /// guard and bails — this is what defuses the orphan-listener cascade.
  void _teardown() {
    _connectWatchdog?.cancel();
    _connectWatchdog = null;

    final old = _socket;
    _socket = null;
    _generation++;

    if (old != null) {
      try {
        old.off('connect');
        old.off('authenticated');
        old.off('exception');
        old.off('disconnect');
        old.off('connect_error');
        old.dispose();
      } catch (_) {}
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();

    if (_reconnectAttempts >= _maxReconnectAttempts) {
      _teardown();
      _setStatus(StreamingStatus.disconnected);
      _reconnectAttempts = 0;
      return;
    }

    final delayMs = (_baseReconnectDelay.inMilliseconds *
            (1 << _reconnectAttempts.clamp(0, 16)))
        .clamp(0, _maxReconnectDelay.inMilliseconds);
    _reconnectAttempts += 1;

    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      if (_disposed || _status == StreamingStatus.connected) return;
      _teardown();
      _open();
    });
  }

  String _buildUrl() {
    final scheme = credentials.isSecure ? 'https' : 'http';
    final host = credentials.host;
    final rawPort = credentials.port;
    final int? port = (rawPort == 0 || rawPort == null) ? null : rawPort;
    if (port == null || port == 80 || port == 443) {
      return '$scheme://$host';
    }
    return '$scheme://$host:$port';
  }

  @override
  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempts = 0;
    _lastConnectAttempt = null; // explicit disconnect — let next connect() run.
    _rejectedAccessToken = null;
    _teardown();
    _setStatus(StreamingStatus.disconnected);
  }

  @override
  void send(StreamingRequest request) {
    if (!isConnected) return;
    final options = request.onRequest();
    for (final i in interceptors) i.onRequest(options);
    _socket?.emit(options.action, options.data);
  }

  @override
  Future<R> sendRequest<R>(StreamingRequest<R> request) {
    if (!isConnected) throw StreamingNotConnectedException();
    final completer = Completer<R>();
    final options = request.onRequest();
    for (final i in interceptors) i.onRequest(options);
    _socket?.emitWithAck(options.action, options.data, ack: (response) {
      final data =
          (response is Map<String, dynamic>) ? response : {'data': response};
      final streamResponse = StreamingResponse(data: data);
      for (final i in interceptors) i.onResponse(streamResponse);
      try {
        completer.complete(request.onResponse(streamResponse));
      } catch (e) {
        completer.completeError(e);
      }
    });
    return completer.future.timeout(retryConfig.maxDelay);
  }

  @override
  Stream<T> on<T>(StreamingEvent<T> eventParser) {
    final controller = StreamController<T>();
    final type = eventParser.type;

    void handler(data) {
      if (controller.isClosed) return;
      final map = (data is Map<String, dynamic>) ? data : {'data': data};
      final json = JsonObject(map);
      try {
        controller.add(eventParser.onResponse(json));
      } catch (_) {}
    }

    _socket?.on(type, handler);
    _activeListeners.putIfAbsent(type, () => []).add(handler);

    controller.onCancel = () {
      _socket?.off(type, handler);
      _activeListeners[type]?.remove(handler);
      if (_activeListeners[type]?.isEmpty ?? false) {
        _activeListeners.remove(type);
      }
      controller.close();
    };

    return controller.stream;
  }

  void _applyActiveListeners(io.Socket s) {
    _activeListeners.forEach((type, handlers) {
      for (final handler in handlers) {
        s.on(type, handler);
      }
    });
  }

  @override
  void registerPersistentRequest(StreamingRequest request) {
    _persistentRequests.add(request);
    if (isConnected) send(request);
  }

  @override
  void unregisterPersistentRequest(StreamingRequest request) {
    _persistentRequests.remove(request);
  }

  void _flushPersistentRequests() {
    for (final req in _persistentRequests) send(req);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectWatchdog?.cancel();
    _connectWatchdog = null;
    _teardown();
    _setStatus(StreamingStatus.disconnected);
    _statusController.close();
  }
}
