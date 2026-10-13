import '../shared/types.dart';
import '../responses/example_response.dart';

/// Example: POST with JSON body.
class ExampleCreateRequest extends JsonRequest<ExampleResponse> {
  final String title;

  ExampleCreateRequest({
    required this.title,
  }) : super('/api/v1/examples');

  @override
  HttpOptions onRequest(ApiCredentials credentials) {
    return HttpOptions.post(
      path,
      HttpData.json({'title': title}),
    );
  }

  @override
  ExampleResponse onJsonResponse(JsonObject json, HttpResponse response) {
    return ExampleResponse.fromJson(json);
  }
}
