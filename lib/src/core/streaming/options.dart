import 'protocol.dart';

/// Options for a streaming request.
class StreamingOptions {
  final String action;
  final Map<String, dynamic> data;
  final Map<String, dynamic> extras;

  /// Trace ID for end-to-end observability in microservices.
  /// Used to link mobile logs with backend logs.
  final String? correlationId;

  const StreamingOptions({
    required this.action,
    this.data = const {},
    this.extras = const {},
    this.correlationId,
  });

  /// Outgoing envelope; field names come from [protocol].
  Map<String, dynamic> toJson(
          [StreamingProtocol protocol = StreamingProtocol.standard]) =>
      protocol.envelope(this);
}
