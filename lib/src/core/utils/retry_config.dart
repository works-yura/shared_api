class RetryConfig {
  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;

  const RetryConfig({
    this.maxAttempts = 5,
    this.initialDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 5),
  });

  /// Calculate delay: initialDelay * 2^(attempt - 1)
  Duration getDelayForAttempt(int attempt) {
    if (attempt <= 0) return Duration.zero;
    final factor = 1 << (attempt - 1); // 2^(attempt-1)
    final delay = initialDelay * factor;
    return delay > maxDelay ? maxDelay : delay;
  }
}
