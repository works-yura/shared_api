import 'package:flutter/foundation.dart';
import 'package:shared_api/shared_api.dart';

/// Concrete implementation of [Coordinator] for Shared API.
///
/// Living in `src/`, it has access to all specific clients and services.
class ApiCoordinator extends Coordinator<TokenState> {
  final HttpClient<TokenState, ApiCredentials> _client;
  final MessagingService? _messagingService;
  final RefreshRequestFactory _refreshRequestFactory;

  /// HTTP cache cleared on sign-out / account switch, so one user's cached
  /// responses are never served to another.
  final HttpCache? _cache;

  /// Resolves who owns the cached responses for an authorized session.
  final String Function(AuthorizedState state) _userIdResolver;

  /// User the cached responses belong to. `_unknownOwner` until the first
  /// session event, so the initial restore doesn't wipe the cache.
  Object? _cacheOwner = _unknownOwner;
  static const _unknownOwner = Object();

  ApiCoordinator({
    required super.session,
    required super.connectivity,
    required HttpClient<TokenState, ApiCredentials> client,
    required RefreshRequestFactory refreshRequestFactory,
    super.streaming,
    MessagingService? messagingService,
    HttpCache? cache,
    String Function(AuthorizedState state)? userIdResolver,
    super.observers,
    super.retry,
  })  : _client = client,
        _messagingService = messagingService,
        _cache = cache,
        _userIdResolver = userIdResolver ?? _defaultUserId,
        _refreshRequestFactory = refreshRequestFactory;

  @override
  void setup() {
    super.setup();
    // Specific initialization if needed
  }

  @override
  Future<void> onNetworkRestored() async {
    final state = await session.read();
    if (state is AuthorizedState) {
      // Refresh timers are not scheduled while offline, so always reschedule
      // here. refreshDelay already shortens the wait for near-expiry tokens.
      _performTokenRefresh(state);
      streaming?.connect();
    }
  }

  bool _isRefreshing = false;

  @override
  void onSessionChanged(TokenState? state) {
    _syncCacheOwner(state);

    if (state is AuthorizedState) {
      final delay = state.refreshDelay;
      debugPrint(
          '[ApiCoordinator] Session changed: Authorized (userId: ${state.userId}). Next refresh in ${delay.inMinutes}m ${delay.inSeconds % 60}s');

      _performTokenRefresh(state);

      if (isOnline) {
        // Streaming handshake carries the access token in its `auth` payload —
        // when it changes we need a fresh socket. `disconnect()` does a safe
        // teardown (generation bump, listener cleanup) so the immediate
        // `connect()` runs against a clean slate.
        if (streaming?.isConnected ?? false) {
          debugPrint(
              '[ApiCoordinator] Forcing streaming reconnection for new Authorized session...');
          streaming?.disconnect();
        } else {
          debugPrint('[ApiCoordinator] Initiating new streaming connection...');
        }
        streaming?.connect();
      }
    } else {
      debugPrint(
          '[ApiCoordinator] Session changed: ${state.runtimeType}. Disconnecting streaming.');
      streaming?.disconnect();
    }
  }

  /// JWT `sub` when available. Opaque tokens carry no identity, so fall back
  /// to the refresh token: the cache is then cleared on every token rotation,
  /// which is safe but loses cached data. Pass [userIdResolver] (e.g. the id
  /// from your profile/sign-in response) to keep the cache across refreshes.
  static String _defaultUserId(AuthorizedState state) {
    final userId = state.userId;
    return userId.isNotEmpty ? userId : 'refresh:${state.refresh}';
  }

  void _syncCacheOwner(TokenState? state) {
    final owner = state is AuthorizedState ? _userIdResolver(state) : null;
    final previous = _cacheOwner;
    _cacheOwner = owner;
    if (identical(previous, _unknownOwner) || previous == owner) return;
    debugPrint('[ApiCoordinator] Session owner changed. Clearing HTTP cache.');
    _cache?.clear();
  }

  @override
  void onStreamingStatusChanged(StreamingStatus status) {
    if (status == StreamingStatus.connected) {
      _messagingService?.flushPending();
    }
  }

  @override
  void onRefreshMaxAttemptsReached() {
    debugPrint('[ApiCoordinator] Max refresh attempts reached');
    session.update(
        TokenState.unauthorized(reason: UnauthorizedReason.sessionExpired));
  }

  void _performTokenRefresh(AuthorizedState state) {
    scheduleRefresh(state.refreshDelay, () async {
      if (_isRefreshing) {
        debugPrint(
            '[ApiCoordinator] Refresh already in progress, skipping scheduled task');
        return true;
      }

      debugPrint('[ApiCoordinator] Starting token refresh...');
      _isRefreshing = true;
      try {
        final request = _refreshRequestFactory(state.refresh);
        final result = await _client.execute<TokenResponse>(request);

        if (result.isFailed()) {
          final failure =
              result.fold((f) => f, (s) => throw StateError('Unreachable'));
          debugPrint('[ApiCoordinator] Refresh failed: $failure');

          if (failure is HttpResponseException &&
              (failure.status == 401 || failure.status == 403)) {
            await session.update(TokenState.unauthorized(
                reason: UnauthorizedReason.sessionExpired));
            return true; // Stop retrying on auth errors
          }
          return false;
        }

        debugPrint('[ApiCoordinator] Refresh successful');
        return true;
      } finally {
        _isRefreshing = false;
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
    _messagingService?.dispose();
  }
}
