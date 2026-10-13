# shared_api

Standalone API layer: HTTP client (dio + interceptors), session/token management,
coordinator (token refresh, reconnect), Socket.IO streaming, outbox, validation.

`lib/src/data/requests` and `lib/src/data/responses` contain **examples only** —
replace them with the real API.

## Example

```dart
final session = SharedApiSession(
  onSave: (TokenState state) async {/* persist */},
  onDelete: () async {/* clear */},
  onLoad: () async => null, // restore persisted TokenState
);
const config = HttpConfig();
final cache = MapHttpCache(maxEntries: 200);

final client = ApiClient<TokenState, ApiCredentials>(
  dio: DioFactory(config: config).create(),
  config: config,
  session: session,
  cache: cache, // CacheInterceptor is installed automatically
  credentials: const ApiCredentials(
    host: 'api.example.com',
    clientID: '',
    clientSecret: '',
  ),
);

final coordinator = ApiCoordinator(
  session: session,
  connectivity: RealNetworkConnectivity(),
  client: client,
  cache: cache, // cleared on sign-out / account switch
  refreshRequestFactory: (token) => AuthRefreshRequest(refreshToken: token),
)..setup();

// Sign in — tokens are written to the session via TokenSessionMixin
final signIn = await client.execute<TokensResponse>(
  AuthSignInRequest(email: 'user@example.com', password: 'password'),
);

final list = await client.execute<List<ExampleResponse>>(
  ExampleGetListRequest(page: 1),
);

list.fold(
  (failure) => print('Failed: $failure'),
  (items) => print('Loaded ${items.length} items'),
);
```

## Adding a request

```dart
class ExampleGetOneRequest extends JsonRequest<ExampleResponse> {
  final String id;

  ExampleGetOneRequest({required this.id}) : super('/api/v1/examples/$id');

  @override
  HttpOptions onRequest(ApiCredentials credentials) => HttpOptions.get(path);

  @override
  ExampleResponse onJsonResponse(JsonObject json, HttpResponse response) =>
      ExampleResponse.fromJson(json);
}
```

## Caching

Caching is **opt-in per request** (default `HttpCachePolicy.noCache`), only for GET.
`ApiClient` installs `CacheInterceptor` first in the dio chain, so a cache hit
skips auth, retry and network.

| Policy | Fresh entry | Expired entry | Miss |
|---|---|---|---|
| `noCache` | network, not stored | network, not stored | network |
| `useCache` | cache | conditional GET (ETag / Last-Modified), `304` extends entry | network, stored |
| `staleWhileRevalidate` | cache | stale cache now + one background refresh | network, stored |
| `refresh` | network, stored | network, stored | network, stored |
| `onlyCache` | cache | stale cache | error |

```dart
@override
HttpOptions onRequest(ApiCredentials credentials) =>
    HttpOptions.get(path).copyWith(
      cachePolicy: HttpCachePolicy.staleWhileRevalidate,
    );
```

- TTL comes from `Cache-Control: max-age` / `Expires`, else `CacheInterceptor.defaultTtl` (5 min).
  `no-store` is never stored; `no-cache` is stored but always revalidated.
- Responses served from cache carry `x-from-cache: true`; stale ones also `x-cache-stale: true`.
- `HttpCache.get` returns expired entries; implementations own eviction.
  `MapHttpCache` evicts least recently used past `maxEntries` and entries expired longer than `maxStale` (1 day).
- Use `staleWhileRevalidate` only for non-critical read-only data (catalogs, lists),
  never for balances, permissions or anything the user just changed.

## Tree

```bash
lib
  - shared_api.dart          # barrel
  - src
    - coordinator.dart       # ApiCoordinator (refresh, reconnect)
    - shared_api_client.dart
    - core                   # abstractions: http, session, streaming, outbox, cache, codec, utils (Try)
    - drivers                # implementations: dio client + interceptors, session, socket.io, validation
    - data
      - shared               # BaseRequest, JsonRequest, TokenSessionMixin, ApiCredentials
      - requests             # examples
      - responses            # examples
```
