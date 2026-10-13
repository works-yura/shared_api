/// HTTP request method.
enum HttpMethod {
  get('GET'),
  post('POST'),
  patch('PATCH'),
  put('PUT'),
  delete('DELETE'),
  head('HEAD'),
  options('OPTIONS');

  /// Wire value sent in the request line.
  final String value;

  const HttpMethod(this.value);

  W when<W>({
    W Function()? get,
    W Function()? post,
    W Function()? patch,
    W Function()? put,
    W Function()? delete,
    W Function()? head,
    W Function()? options,
    required W Function() other,
  }) {
    final handler = switch (this) {
      HttpMethod.get => get,
      HttpMethod.post => post,
      HttpMethod.patch => patch,
      HttpMethod.put => put,
      HttpMethod.delete => delete,
      HttpMethod.head => head,
      HttpMethod.options => options,
    };
    return (handler ?? other).call();
  }

  @override
  String toString() => value;
}
