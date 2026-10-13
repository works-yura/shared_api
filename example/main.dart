import 'package:shared_api/shared_api.dart';

Future<void> main() async {
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
}
