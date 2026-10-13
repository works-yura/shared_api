class HttpResponse {
  final int status;
  final Map<String, List<String>> headers;
  final dynamic data;

  const HttpResponse({
    required this.status,
    required this.headers,
    required this.data,
  });
}
