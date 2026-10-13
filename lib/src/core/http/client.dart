import 'package:shared_api/src/core/utils/try.dart';
import 'package:shared_api/src/core/session/session.dart';
import 'package:shared_api/src/core/http/request.dart';
import 'package:shared_api/src/core/http/cancel.dart';
import 'package:shared_api/src/core/exceptions/exception.dart';
import 'package:shared_api/src/core/http/credentials.dart';

abstract class HttpClient<State extends HttpState,
    Credentials extends HttpCredentials> {
  HttpSession<State> get session;
  Credentials get credentials;

  Future<Try<HttpException, T>> execute<T>(
      HttpRequest<State, Credentials, T> request,
      {HttpCancelToken? cancelToken});

  Future<Try<HttpException, void>> uploadFile(String url, String filePath,
      {Map<String, String>? headers,
      HttpCancelToken? cancelToken,
      void Function(int sent, int total)? onProgress});
}
