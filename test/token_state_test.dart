import 'package:flutter_test/flutter_test.dart';
import 'package:shared_api/src/drivers/session/state.dart';
import 'package:shared_api/src/data/responses/responses.dart';
import 'package:shared_api/src/data/shared/types.dart';

void main() {
  group('AuthorizedStateX.refreshDelay', () {
    test('calculates correct delay for a fresh token', () {
      final now = DateTime.now();
      final state = TokenState.authorized(
        access: 'access',
        refresh: 'refresh',
        expiresIn: 3600, // 1 hour
        createdAt: now,
      ) as AuthorizedState;

      // Buffer = 10% of 3600 = 360s (fixed at max 300s)
      // Ideal refresh = 3600 - 300 = 3300s from creation
      // Delay should be around 3300s
      expect(state.refreshDelay.inSeconds, inInclusiveRange(3290, 3310));
    });

    test('applies min delay of 30s for tokens nearly expired but just created',
        () {
      final now = DateTime.now();
      final state = TokenState.authorized(
        access: 'access',
        refresh: 'refresh',
        expiresIn: 10, // Expiring in 10s
        createdAt: now,
      ) as AuthorizedState;

      // Because it's very recent (age < 30s), it should wait at least 30s
      expect(state.refreshDelay.inSeconds, equals(30));
    });

    test('waits a 10s floor for expired tokens created long ago', () {
      final longAgo = DateTime.now().subtract(const Duration(hours: 2));
      final state = TokenState.authorized(
        access: 'access',
        refresh: 'refresh',
        expiresIn: 3600, // 1 hour
        createdAt: longAgo,
      ) as AuthorizedState;

      // Floor prevents a tight refresh loop on clock skew / failed refresh.
      expect(state.refreshDelay, equals(const Duration(seconds: 10)));
    });

    test('clamps buffer between 30s and 300s', () {
      // Case 1: Very long lived token (1 day = 86400s)
      // 10% = 8640s -> clamped to 300s
      final state1 = TokenState.authorized(
        access: 'access',
        refresh: 'refresh',
        expiresIn: 86400,
        createdAt: DateTime.now(),
      ) as AuthorizedState;
      expect(86400 - state1.refreshDelay.inSeconds, inInclusiveRange(290, 310));

      // Case 2: Very short lived token (100s)
      // 10% = 10s -> clamped to 30s
      final state2 = TokenState.authorized(
        access: 'access',
        refresh: 'refresh',
        expiresIn: 100,
        createdAt: DateTime.now(),
      ) as AuthorizedState;
      expect(100 - state2.refreshDelay.inSeconds, inInclusiveRange(25, 35));
    });
  });

  group('TokensResponse.fromJson', () {
    test('parses camelCase expiresIn', () {
      final json = JsonObject({
        'accessToken': 'a',
        'refreshToken': 'r',
        'expiresIn': 3600,
      });
      final response = TokensResponse.fromJson(json);
      expect(response.expiresIn, equals(3600));
    });

    test('parses snake_case expires_in', () {
      final json = JsonObject({
        'accessToken': 'a',
        'refreshToken': 'r',
        'expires_in': 3600,
      });
      final response = TokensResponse.fromJson(json);
      expect(response.expiresIn, equals(3600));
    });

    test('prefers camelCase if both present', () {
      final json = JsonObject({
        'accessToken': 'a',
        'refreshToken': 'r',
        'expiresIn': 100,
        'expires_in': 200,
      });
      final response = TokensResponse.fromJson(json);
      expect(response.expiresIn, equals(100));
    });
  });
}
