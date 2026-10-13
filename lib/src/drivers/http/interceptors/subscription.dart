import 'package:dio/dio.dart';

/// Intercepts 402 Payment Required errors with code 'SUBSCRIPTION_REQUIRED'
/// and forwards them to [onSubscriptionRequired].
class SubscriptionInterceptor extends Interceptor {
  final void Function() onSubscriptionRequired;

  SubscriptionInterceptor({required this.onSubscriptionRequired});

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 402) {
      final data = err.response?.data;
      if (data is Map) {
        final metadata = data['metadata'];
        final code =
            data['code'] ?? (metadata is Map ? metadata['code'] : null);
        if (code == 'SUBSCRIPTION_REQUIRED') {
          onSubscriptionRequired();
        }
      }
    }
    super.onError(err, handler);
  }
}
