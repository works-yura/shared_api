import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

/// Adds an `Idempotency-Key` header to mutating requests so the server can
/// safely deduplicate retries (network glitches, app resume, websocket
/// reconnect flush, etc.) without re-executing the side effects.
///
/// Behaviour:
///   - Only [methods] (POST/PATCH/PUT/DELETE by default) get a key.
///   - If the request already has [headerName] set (caller supplied a
///     deterministic key, e.g. `like:<userId>:<targetId>`), respect it.
///   - Otherwise generate a v4 UUID — Dio retains the same RequestOptions
///     across retries, so the key stays stable for the lifetime of the call.
///
/// [RetryInterceptor] treats requests carrying this header as safe to retry;
/// when using a custom [headerName], pass the same name to
/// [RetryInterceptor.isIdempotentRequest] in a custom `retryIf`.
class IdempotencyInterceptor extends InterceptorsWrapper {
  /// Default header carrying the idempotency key.
  static const defaultHeaderName = 'Idempotency-Key';

  /// Default HTTP methods that get a key.
  static const defaultMethods = {'POST', 'PATCH', 'PUT', 'DELETE'};

  static final _uuid = const Uuid();

  /// Header carrying the idempotency key.
  final String headerName;

  /// Upper-case HTTP methods that get a key.
  final Set<String> methods;

  IdempotencyInterceptor({
    this.headerName = defaultHeaderName,
    this.methods = defaultMethods,
  });

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    final method = options.method.toUpperCase();
    if (methods.contains(method) && !options.headers.containsKey(headerName)) {
      options.headers[headerName] = _uuid.v4();
    }
    handler.next(options);
  }
}
