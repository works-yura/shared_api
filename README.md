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

final client = ApiClient<TokenState, ApiCredentials>(
  dio: DioFactory(config: config).create(),
  config: config,
  session: session,
  cache: MapHttpCache(),
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
