library shared_api;

// Core & Session (Essentials)
export 'package:shared_api/src/coordinator.dart';
export 'package:shared_api/src/shared_api_client.dart';

export 'package:shared_api/src/core/core.dart';
export 'package:shared_api/src/drivers/session/session.dart';

// Connectivity
export 'package:shared_api/src/drivers/connection/basic_connectivity.dart';
export 'package:shared_api/src/drivers/connection/real_connectivity.dart';

// HTTP
export 'package:shared_api/src/drivers/http/http.dart';
export 'package:shared_api/src/drivers/http/config.dart';
export 'package:shared_api/src/data/shared/credentials.dart';
export 'package:shared_api/src/drivers/http/factory/dio_factory.dart';
export 'package:shared_api/src/drivers/http/compression/compressors.dart';
// Streaming
export 'package:shared_api/src/drivers/streaming/streaming.dart';
export 'package:shared_api/src/drivers/streaming/socket_io_streaming.dart';
export 'package:shared_api/src/drivers/streaming/messaging/messaging_service.dart';
export 'package:shared_api/src/drivers/streaming/interceptors/interceptors.dart';
export 'package:shared_api/src/drivers/streaming/persistence/persistent_outbox.dart';

// Data Models (examples — replace with real API)
export 'package:shared_api/src/data/shared/types.dart';
export 'package:shared_api/src/data/requests/requests.dart';
export 'package:shared_api/src/data/responses/responses.dart';
// Validation
export 'package:shared_api/src/drivers/validation/validation_engine.dart';
