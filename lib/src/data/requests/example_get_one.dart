import '../shared/types.dart';
import '../responses/example_response.dart';

/// Example: GET single item using [JsonRequest].
class ExampleGetOneRequest extends JsonRequest<ExampleResponse> {
  final String id;

  ExampleGetOneRequest({
    required this.id,
  }) : super('/api/v1/examples/$id');

  @override
  HttpOptions onRequest(ApiCredentials credentials) {
    return HttpOptions.get(path);
  }

  @override
  ExampleResponse onJsonResponse(JsonObject json, HttpResponse response) {
    return ExampleResponse.fromJson(json);
  }
}
