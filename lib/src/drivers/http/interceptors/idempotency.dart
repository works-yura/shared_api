import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

/// Adds an `Idempotency-Key` header to mutating requests so the server can
/// safely deduplicate retries (network glitches, app resume, websocket
/// reconnect flush, etc.) without re-executing the side effects.
///
/// Behaviour:
///   - Only POST/PATCH/PUT/DELETE get a key.
///   - If the request already has `Idempotency-Key` set (caller supplied a
///     deterministic key, e.g. `like:<userId>:<targetId>`), respect it.
///   - Otherwise generate a v4 UUID — Dio retains the same RequestOptions
///     across retries, so the key stays stable for the lifetime of the call.
class IdempotencyInterceptor extends InterceptorsWrapper {
  static const _headerName = 'Idempotency-Key';
  static const _mutating = {'POST', 'PATCH', 'PUT', 'DELETE'};
  static final _uuid = const Uuid();

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    final method = options.method.toUpperCase();
    if (_mutating.contains(method) &&
        !options.headers.containsKey(_headerName)) {
      options.headers[_headerName] = _uuid.v4();
    }
    handler.next(options);
  }
}
