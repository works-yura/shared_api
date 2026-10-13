/// Abstract token to cancel HTTP requests.
abstract class HttpCancelToken {
  void cancel([dynamic reason]);
  bool get isCancelled;
}
