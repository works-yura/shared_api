import 'dart:math' show Random;

class DeviceId {
  static const int defaultLength = 40;
  static const String _chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  static String generate([int length = defaultLength]) {
    final random = Random.secure();
    final buffer = StringBuffer();

    for (var i = 0; i < length; i++) {
      final index = random.nextInt(_chars.length);
      buffer.write(_chars[index]);
    }

    return buffer.toString();
  }
}
