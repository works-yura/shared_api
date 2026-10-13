class HttpMethod {
  static const HttpMethod GET = HttpMethod._('GET');
  static const HttpMethod POST = HttpMethod._('POST');
  static const HttpMethod PATCH = HttpMethod._('PATCH');
  static const HttpMethod PUT = HttpMethod._('PUT');
  static const HttpMethod DELETE = HttpMethod._('DELETE');
  static const HttpMethod HEAD = HttpMethod._('HEAD');
  static const HttpMethod OPTIONS = HttpMethod._('OPTIONS');

  final String value;

  const HttpMethod._(this.value);

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
      GET => get,
      POST => post,
      PATCH => patch,
      PUT => put,
      DELETE => delete,
      HEAD => head,
      OPTIONS => options,
      _ => other,
    };
    return (handler ?? other).call();
  }

  @override
  String toString() => value;
}
