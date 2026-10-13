import 'package:shared_api/shared_api.dart';

Future<void> main() async {
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
}
