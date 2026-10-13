import 'dart:async';
import '/src/core/core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'access_token.dart';

/// Represents the internal state of the WebSocket connection.
sealed class WSState {
  const WSState();
  StreamingStatus get status;
}

class DisconnectedState extends WSState {
  final Object? lastError;
  const DisconnectedState([this.lastError]);
  @override
  StreamingStatus get status => StreamingStatus.disconnected;
}

class ConnectingState extends WSState {
  const ConnectingState();
  @override
  StreamingStatus get status => StreamingStatus.connecting;
}

class ConnectedState extends WSState {
  final Codec codec;
  final String protocol;
  const ConnectedState({required this.codec, required this.protocol});
  @override
  StreamingStatus get status => StreamingStatus.connected;
}

class ReconnectingState extends WSState {
  final int attempt;
  final Object? lastError;
  const ReconnectingState({required this.attempt, this.lastError});
  @override
  StreamingStatus get status => StreamingStatus.reconnecting;
}

/// WebSocket implementation of [Streaming].
///
/// Enterprise-grade client with Heartbeat, State Machine, and Interceptors.
class WebSocketStreaming<S extends HttpState, C extends HttpCredentials>
    implements Streaming {
  final C credentials;
  final HttpSession<S>? session;
  final RetryConfig retryConfig;

  /// Available codecs for negotiation (protocol_name -> codec)
  final Map<String, Codec> codecs;

  /// Protocol to use if negotiation fails or is not supported
  final String defaultProtocol;

  @override
  final List<StreamingInterceptor> interceptors;

  final Duration heartbeatInterval;
  final Duration requestTimeout;

  /// Wire names: event routing, correlation id, envelope, ping/pong.
  final StreamingProtocol protocol;

  /// Endpoint path, appended to `credentials.path`.
  final String path;

  /// Extracts the access token from the session state; null keeps the
  /// stream disconnected. Defaults to [sessionAccessToken].
  final StreamingTokenResolver<S> accessToken;

  /// Query parameter carrying the access token (`?token=`), or null to keep
  /// the token out of the URL.
  ///
  /// The default is kept only because existing servers read the token from
  /// the query string. URLs are routinely written to proxy, load balancer and
  /// server access logs, so a token there can leak. Browsers cannot set
  /// headers on a WebSocket handshake; prefer setting this to null and
  /// authenticating with [authMessage] when the server supports it.
  final String? tokenQueryParameter;

  /// Optional first frame sent right after the socket opens, before any
  /// other message, e.g. `(t) => {'type': 'auth', 'token': t}`.
  final Map<String, dynamic> Function(String token)? authMessage;

  WebSocketChannel? _channel;
  WSState _internalState = const DisconnectedState();

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  // Request-Response correlation
  final Map<String, Completer<StreamingResponse>> _pendingRequests = {};

  // Persistent requests (subscriptions) that are re-sent on reconnection
  final Set<StreamingRequest> _persistentRequests = {};

  final _eventController = StreamController<dynamic>.broadcast();
  final _statusController = StreamController<StreamingStatus>.broadcast();

  WebSocketStreaming({
    required this.credentials,
    required this.codecs,
    required this.defaultProtocol,
    this.session,
    this.interceptors = const [],
    this.retryConfig = const RetryConfig(),
    this.heartbeatInterval = const Duration(seconds: 30),
    this.requestTimeout = const Duration(seconds: 15),
    this.protocol = StreamingProtocol.standard,
    this.path = '/ws',
    this.accessToken = sessionAccessToken,
    this.tokenQueryParameter = 'token',
    this.authMessage,
  });

  @override
  dynamic prepare(Map<String, dynamic> data) {
    if (_internalState is ConnectedState) {
      return (_internalState as ConnectedState).codec.encode(data);
    }
    return codecs[defaultProtocol]?.encode(data) ?? data;
  }

  @override
  Stream<StreamingStatus> get status => _statusController.stream;

  @override
  StreamingStatus get currentStatus => _internalState.status;

  @override
  bool get isConnected => _internalState is ConnectedState;

  /// Current active codec (negotiated or default).
  Codec get codec {
    final state = _internalState;
    if (state is ConnectedState) return state.codec;
    return codecs[defaultProtocol]!;
  }

  // ==========================================================================
  // State Machine Logic
  // ==========================================================================

  void _transition(WSState newState) {
    if (_internalState.runtimeType == newState.runtimeType &&
        newState is! ReconnectingState) return;

    final oldState = _internalState;
    _internalState = newState;

    // Side Effects Management
    _handleStateExit(oldState);
    _handleStateEntry(newState);

    _statusController.add(newState.status);
    for (var i in interceptors) i.onStatusChanged(newState.status);
  }

  void _handleStateEntry(WSState state) {
    switch (state) {
      case ConnectedState():
        _startHeartbeat();
        _flushPersistentRequests();
      case ReconnectingState(attempt: var a):
        final delay = retryConfig.getDelayForAttempt(a);
        _reconnectTimer = Timer(delay, _establishConnection);
      case DisconnectedState():
        _stopHeartbeat();
        _cleanupPendingRequests(StreamingDisconnectedException());
      case ConnectingState():
        break;
    }
  }

  void _handleStateExit(WSState state) {
    if (state is ConnectedState) {
      _stopHeartbeat();
    }
    if (state is ReconnectingState) {
      _reconnectTimer?.cancel();
    }
  }

  void _cleanupPendingRequests(Exception e) {
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }
    _pendingRequests.clear();
  }

  // ==========================================================================
  // Connection Management
  // ==========================================================================

  @override
  Future<void> connect() async {
    if (_internalState is ConnectedState || _internalState is ConnectingState)
      return;

    _transition(const ConnectingState());
    await _establishConnection();
  }

  Future<void> _establishConnection() async {
    try {
      final token = accessToken(await session?.read());

      if (token == null) {
        _transition(
            DisconnectedState(Exception('Unauthorized or no token available')));
        return;
      }

      final uri = _buildUri(token);
      _channel = WebSocketChannel.connect(
        uri,
        protocols: codecs.keys.toList(),
      );

      await _channel!.ready;

      // Negotiation: Server selects one of our protocols
      final negotiated = _channel!.protocol;
      final selectedCodec = codecs[negotiated] ?? codecs[defaultProtocol]!;

      final auth = authMessage;
      if (auth != null) _channel!.sink.add(selectedCodec.encode(auth(token)));

      _transition(ConnectedState(
          codec: selectedCodec, protocol: negotiated ?? 'unknown'));

      _channel!.stream.listen(
        _onMessage,
        onDone: () => _handleDisconnect(),
        onError: (e) => _handleDisconnect(e),
      );
    } catch (e, s) {
      _notifyError(e, s);
      _handleDisconnect(e);
    }
  }

  void _handleDisconnect([Object? error]) {
    final currentState = _internalState;

    if (currentState is DisconnectedState) return;

    if (error != null) _notifyError(error);
    _channel = null;

    int nextAttempt = 0;
    if (currentState is ReconnectingState)
      nextAttempt = currentState.attempt + 1;
    if (currentState is ConnectedState || currentState is ConnectingState)
      nextAttempt = 1;

    _transition(ReconnectingState(attempt: nextAttempt, lastError: error));
  }

  @override
  Future<void> disconnect() async {
    _transition(const DisconnectedState());
    await _channel?.sink.close();
    _channel = null;
  }

  // ==========================================================================
  // Heartbeat
  // ==========================================================================

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (timer) {
      if (isConnected) {
        _sendRaw(protocol.ping);
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ==========================================================================
  // Message Handling
  // ==========================================================================

  void _onMessage(dynamic message) async {
    try {
      // Async decode with Isolate
      final Map<String, dynamic> data = await codec.decode(message);

      final type = protocol.typeOf(data);
      final response = StreamingResponse(data: data, type: type);

      // 1. Intercept Response
      for (final i in interceptors) {
        i.onResponse(response);
      }

      if (type == protocol.pongType) return;

      final correlationId = data[protocol.correlationIdField] as String?;
      if (correlationId != null &&
          _pendingRequests.containsKey(correlationId)) {
        final completer = _pendingRequests.remove(correlationId)!;
        if (!completer.isCompleted) {
          completer.complete(response);
        }
        return;
      }

      _eventController.add(data);
    } catch (e, s) {
      _notifyError(e, s);
    }
  }

  // ==========================================================================
  // Sending Messages
  // ==========================================================================

  @override
  void send(StreamingRequest request) {
    if (!isConnected) return;

    if (request is RawStreamingRequest) {
      _channel?.sink.add(request.payload);
      return;
    }

    final options = request.onRequest();

    // Intercept Request
    for (final i in interceptors) {
      i.onRequest(options);
    }

    _sendRaw(options.toJson(protocol));
  }

  @override
  Future<R> sendRequest<R>(StreamingRequest<R> request) async {
    if (!isConnected) {
      throw StreamingNotConnectedException();
    }

    if (request is RawStreamingRequest) {
      final raw = request as RawStreamingRequest;
      _channel?.sink.add(raw.payload);
      return request.onResponse(const StreamingResponse(data: {}));
    }

    try {
      final correlationId = DeviceId.generate(16);
      final completer = Completer<StreamingResponse>();

      final options = request.onRequest();
      final payload = options.toJson(protocol)
        ..[protocol.correlationIdField] = correlationId;

      // Intercept Request
      for (final i in interceptors) {
        i.onRequest(options);
      }

      _pendingRequests[correlationId] = completer;
      _sendRaw(payload);

      final response = await completer.future.timeout(requestTimeout);
      return request.onResponse(response);
    } on TimeoutException {
      // ignore
      throw StreamingTimeoutException('request_timeout');
    } catch (e) {
      final exception =
          (e is StreamingException) ? e : StreamingException(e.toString());
      throw request.onException(exception);
    }
  }

  void _sendRaw(Map<String, dynamic> payload) {
    _channel?.sink.add(codec.encode(payload));
  }

  // ==========================================================================
  // Persistent Requests (Subscriptions)
  // ==========================================================================

  @override
  void registerPersistentRequest(StreamingRequest request) {
    _persistentRequests.add(request);
    if (isConnected) {
      send(request);
    }
  }

  @override
  void unregisterPersistentRequest(StreamingRequest request) {
    _persistentRequests.remove(request);
  }

  void _flushPersistentRequests() {
    for (final request in _persistentRequests) {
      send(request);
    }
  }

  // ==========================================================================
  // Event Subscription
  // ==========================================================================

  @override
  Stream<T> on<T>(StreamingEvent<T> eventParser) {
    return _eventController.stream
        .where((data) => data is Map<String, dynamic>)
        .map((data) => JsonObject(data as Map<String, dynamic>))
        .where((json) =>
            json.as<String>(protocol.typeField, '') == eventParser.type)
        .map((json) => eventParser.onResponse(json));
  }

  // ==========================================================================
  // Internal Helpers
  // ==========================================================================

  void _notifyError(Object error, [StackTrace? stackTrace]) {
    for (final i in interceptors) {
      i.onError(error, stackTrace);
    }
  }

  Uri _buildUri(String token) {
    final param = tokenQueryParameter;
    return Uri(
      scheme: credentials.isSecure ? 'wss' : 'ws',
      host: credentials.host,
      port: credentials.port,
      path: '${credentials.path ?? ''}$path',
      queryParameters: param == null ? null : {param: token},
    );
  }

  @override
  void dispose() {
    disconnect();
    _eventController.close();
    _statusController.close();

    _cleanupPendingRequests(StreamingDisconnectedException());
    _persistentRequests.clear();
  }
}

// ============================================================================
// Exceptions
// ============================================================================
