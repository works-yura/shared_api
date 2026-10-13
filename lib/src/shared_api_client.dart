import 'core/core.dart';
import 'data/shared/credentials.dart';
import 'drivers/session/state.dart';

/// A concrete [HttpClient] specific to the Shared API.
///
/// It uses [TokenState] for session management and [ApiCredentials] for configuration.
typedef SharedApiClient = HttpClient<TokenState, ApiCredentials>;
