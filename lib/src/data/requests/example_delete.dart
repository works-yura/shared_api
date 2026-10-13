import '../shared/types.dart';

/// Example: DELETE without response body.
class ExampleDeleteRequest extends BaseRequest<void> {
  final String id;

  ExampleDeleteRequest({
    required this.id,
  }) : super('/api/v1/examples/$id');

  @override
  HttpOptions onRequest(ApiCredentials credentials) {
    return HttpOptions.delete(path, HttpData.json({}));
  }
}
