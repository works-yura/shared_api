import 'dart:async';

import 'package:dio/dio.dart';

/// Attaches a Firebase App Check token to every request, so the server can
/// tell the real app (attested by App Attest / Play Integrity) apart from a
/// script calling the API directly.
///
/// The token never blocks a request: if it cannot be obtained in [timeout]
/// (no network to Firebase, attestation unavailable, Firebase not ready yet)
/// the request goes out without the header and the server decides.
///
/// Requests matched by [isOneShot] (sending an OTP) get a limited-use token
/// instead, which the server consumes on first sight — a token lifted from a
/// real device cannot be replayed to send more codes. It is fetched again on
/// every pass, retries included, because the previous one may already have
/// been consumed.
class AppCheckInterceptor extends InterceptorsWrapper {
  static const header = 'X-Firebase-AppCheck';

  final Future<String?> Function() getToken;
  final Future<String?> Function() getLimitedUseToken;
  final bool Function(String path) isOneShot;
  final Duration timeout;

  AppCheckInterceptor({
    required this.getToken,
    required this.getLimitedUseToken,
    this.isOneShot = isOtpSend,
    this.timeout = const Duration(seconds: 3),
  });

  /// Both API versions of the OTP send.
  static bool isOtpSend(String path) =>
      Uri.parse(path).path.endsWith('/authentication/phone/send-otp');

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final fetch = isOneShot(options.path) ? getLimitedUseToken : getToken;
    final token = await tryAppCheckToken(fetch, timeout);
    if (token != null) {
      options.headers[header] = token;
    } else {
      options.headers.remove(header);
    }
    return handler.next(options);
  }
}

/// The token from [fetch], or null if it fails, is empty or takes longer than
/// [timeout] — App Check never holds up or breaks a request or a connection.
Future<String?> tryAppCheckToken(
  Future<String?> Function() fetch, [
  Duration timeout = const Duration(seconds: 3),
]) async {
  try {
    final token = await fetch().timeout(timeout);
    return token == null || token.isEmpty ? null : token;
  } catch (_) {
    return null;
  }
}
