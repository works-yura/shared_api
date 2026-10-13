import 'dart:convert';
import 'package:shared_api/src/core/session/session.dart';

enum UnauthorizedReason {
  manualLogout,
  sessionExpired,
  accessDenied,
}

sealed class TokenState extends HttpState {
  const TokenState();

  factory TokenState.authorized({
    required String access,
    required String refresh,
    required int expiresIn,
    DateTime? createdAt,
  }) = AuthorizedState;

  factory TokenState.unauthorized({
    required UnauthorizedReason reason,
  }) = UnauthorizedState;
}

class AuthorizedState extends TokenState {
  final String access;
  final String refresh;
  final int expiresIn;
  final DateTime createdAt;

  AuthorizedState({
    required this.access,
    required this.refresh,
    required this.expiresIn,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get isExpired => willExpireIn(Duration.zero);

  bool willExpireIn(Duration threshold) {
    final expiryDate = createdAt.add(Duration(seconds: expiresIn));
    return DateTime.now().isAfter(expiryDate.subtract(threshold));
  }

  /// Extracts the user ID from the access token (JWT 'sub' claim).
  String get userId {
    try {
      final parts = access.split('.');
      if (parts.length != 3) return '';

      final payload = parts[1];
      final normalized = base64Url.normalize(payload);
      final resp = utf8.decode(base64Url.decode(normalized));
      final payloadMap = json.decode(resp);

      if (payloadMap is! Map<String, dynamic>) return '';
      final sub = payloadMap['sub'];
      return sub is String ? sub : '';
    } catch (e) {
      return '';
    }
  }
}

extension AuthorizedStateX on AuthorizedState {
  Duration get refreshDelay {
    final expiryDate = createdAt.add(Duration(seconds: expiresIn));
    final now = DateTime.now();

    // 1. Calculate buffer (10% of lifetime, between 30s and 5m)
    final buffer = Duration(seconds: (expiresIn * 0.1).clamp(30, 300).toInt());

    // 2. Calculate ideal refresh time
    final refreshTime = expiryDate.subtract(buffer);
    final delay = refreshTime.difference(now);

    // 3. Safety: if we are already very close to expiry or past it,
    // we still want a small delay to prevent immediate recursive calls
    // in case of clock skew or immediate refresh triggers.
    if (delay.inSeconds < 10) {
      // If it just happened (createdAt is very recent), we MUST wait longer to avoid hammering.
      final age = now.difference(createdAt);
      if (age.inSeconds < 30) {
        return const Duration(seconds: 30);
      }
      // Even if it's old/expired, wait at least 10 seconds to prevent tight loops.
      return const Duration(seconds: 10);
    }

    return delay;
  }
}

class UnauthorizedState extends TokenState {
  final UnauthorizedReason reason;

  const UnauthorizedState({required this.reason});
}
