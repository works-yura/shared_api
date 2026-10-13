import '../shared/types.dart';
import '../responses/example_response.dart';

/// Example: GET top-level JSON array using [JsonArrayRequest].
class ExampleGetListRequest extends JsonArrayRequest<ExampleResponse> {
  final int page;
  final int limit;

  ExampleGetListRequest({
    this.page = 1,
    this.limit = 20,
  }) : super('/api/v1/examples');

  @override
  HttpOptions onRequest(ApiCredentials credentials) {
    return HttpOptions.get(
      path,
      queries: {
        'page': page,
        'limit': limit,
      },
    );
  }

  @override
  ExampleResponse mapItem(JsonObject json, HttpResponse response) {
    return ExampleResponse.fromJson(json);
  }
}
