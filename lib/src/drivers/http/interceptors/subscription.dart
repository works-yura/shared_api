import 'package:dio/dio.dart';

/// Forwards "subscription required" errors to [onSubscriptionRequired].
///
/// By default these are 402 Payment Required errors with code
/// 'SUBSCRIPTION_REQUIRED' (top-level `code` or `metadata.code`); pass
/// [matches] for another backend's contract.
class SubscriptionInterceptor extends Interceptor {
  final void Function() onSubscriptionRequired;

  /// Whether an error means a subscription is required.
  final bool Function(DioException error) matches;

  SubscriptionInterceptor({
    required this.onSubscriptionRequired,
    bool Function(DioException error)? matches,
  }) : matches = matches ?? isSubscriptionRequired;

  /// Default [matches]: 402 with code 'SUBSCRIPTION_REQUIRED'.
  static bool isSubscriptionRequired(DioException err) {
    if (err.response?.statusCode != 402) return false;
    final data = err.response?.data;
    if (data is! Map) return false;
    final metadata = data['metadata'];
    final code = data['code'] ?? (metadata is Map ? metadata['code'] : null);
    return code == 'SUBSCRIPTION_REQUIRED';
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (matches(err)) {
      onSubscriptionRequired();
    }
    super.onError(err, handler);
  }
}
