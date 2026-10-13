import 'dart:io' show gzip, zlib;

import 'package:shared_api/src/core/http/compression.dart';

/// `Content-Encoding: gzip` (RFC 1952).
class GzipCompressor extends RequestCompressor {
  const GzipCompressor();

  @override
  String get encoding => 'gzip';

  @override
  List<int> compress(List<int> bytes) => gzip.encode(bytes);
}

/// `Content-Encoding: deflate` (zlib-wrapped DEFLATE, RFC 1950).
class DeflateCompressor extends RequestCompressor {
  const DeflateCompressor();

  @override
  String get encoding => 'deflate';

  @override
  List<int> compress(List<int> bytes) => zlib.encode(bytes);
}
