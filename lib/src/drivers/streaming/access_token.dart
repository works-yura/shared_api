import '/src/core/core.dart';
import '/src/drivers/session/state.dart';

/// Reads the access token a streaming driver authenticates with out of the
/// session state. Returns null when the state carries no usable identity, in
/// which case the driver stays disconnected.
///
/// Lets apps with their own [HttpState] type plug in without the driver
/// knowing that type.
typedef StreamingTokenResolver<S extends HttpState> = String? Function(
    S? state);

/// Default [StreamingTokenResolver]: the access token of an [AuthorizedState],
/// null for anything else.
String? sessionAccessToken(HttpState? state) =>
    state is AuthorizedState ? state.access : null;
