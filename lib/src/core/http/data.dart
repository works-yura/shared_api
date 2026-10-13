abstract class HttpData {
  final Map<String, dynamic> data;

  HttpData(this.data);

  bool isJson() => false;

  bool isMultipart() => false;

  factory HttpData.json(Map<String, dynamic> data) {
    return DataJson(data);
  }

  factory HttpData.multipart(Map<String, dynamic> data) {
    return DataMultipart(data);
  }

  W when<W>({
    W Function(Map<String, dynamic> data)? json,
    W Function(Map<String, dynamic> data)? multipart,
    required W Function(Map<String, dynamic> data) other,
  });
}

class DataJson extends HttpData {
  DataJson(super.data);

  bool isJson() => true;

  @override
  W when<W>({
    W Function(Map<String, dynamic> data)? json,
    W Function(Map<String, dynamic> data)? multipart,
    required W Function(Map<String, dynamic> data) other,
  }) {
    if (json == null) {
      return other.call(data);
    }
    return json.call(data);
  }
}

class DataMultipart extends HttpData {
  DataMultipart(super.data);

  bool isMultipart() => true;

  @override
  W when<W>({
    W Function(Map<String, dynamic> data)? json,
    W Function(Map<String, dynamic> data)? multipart,
    required W Function(Map<String, dynamic> data) other,
  }) {
    if (multipart == null) {
      return other.call(data);
    }
    return multipart.call(data);
  }
}
