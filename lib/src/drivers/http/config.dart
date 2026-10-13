class HttpConfig {
  final Duration connectTimeout;
  final Duration sendTimeout;
  final Duration receiveTimeout;
  final Map<String, String>? headers;
  final List<int>? certificates;
  final Map<String, String> services;
  final bool useGzip;
  final int gzipThreshold;

  const HttpConfig({
    this.connectTimeout = const Duration(seconds: 30),
    this.sendTimeout = const Duration(seconds: 30),
    this.receiveTimeout = const Duration(seconds: 30),
    this.headers,
    this.certificates,
    this.services = const {},
    this.useGzip = true,
    this.gzipThreshold = 1024,
  });

  factory HttpConfig.initial() {
    return const HttpConfig();
  }
}
