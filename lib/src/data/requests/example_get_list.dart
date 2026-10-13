import '../shared/types.dart';
import '../responses/example_response.dart';

/// Example: GET list with query parameters.
class ExampleGetListRequest extends BaseRequest<List<ExampleResponse>> {
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
  List<ExampleResponse> onResponse(HttpResponse response) {
    return (response.data as List)
        .map((e) => ExampleResponse.fromJson(JsonObject(e as Map<String, dynamic>)))
        .toList();
  }
}
