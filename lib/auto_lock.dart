enum AutoLockDelay {
  immediately(Duration.zero, '立即'),
  oneMinute(Duration(minutes: 1), '1 分钟'),
  fiveMinutes(Duration(minutes: 5), '5 分钟'),
  fifteenMinutes(Duration(minutes: 15), '15 分钟'),
  thirtyMinutes(Duration(minutes: 30), '30 分钟'),
  never(null, '从不');

  const AutoLockDelay(this.duration, this.label);

  final Duration? duration;
  final String label;

  int get storedSeconds => duration?.inSeconds ?? -1;

  bool expiredAfter(Duration elapsed) {
    final value = duration;
    return value != null && elapsed >= value;
  }

  static AutoLockDelay fromStoredSeconds(int? seconds) => values.firstWhere(
    (delay) => delay.storedSeconds == seconds,
    orElse: () => fiveMinutes,
  );
}
