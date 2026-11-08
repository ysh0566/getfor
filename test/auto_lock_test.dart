import 'package:flutter_test/flutter_test.dart';
import 'package:getfor/auto_lock.dart';

void main() {
  test(
    'auto-lock delay restores safely and checks elapsed background time',
    () {
      expect(
        AutoLockDelay.fromStoredSeconds(900),
        AutoLockDelay.fifteenMinutes,
      );
      expect(AutoLockDelay.fromStoredSeconds(123), AutoLockDelay.fiveMinutes);
      expect(
        AutoLockDelay.fiveMinutes.expiredAfter(const Duration(minutes: 4)),
        isFalse,
      );
      expect(
        AutoLockDelay.fiveMinutes.expiredAfter(const Duration(minutes: 5)),
        isTrue,
      );
      expect(
        AutoLockDelay.never.expiredAfter(const Duration(days: 1)),
        isFalse,
      );
    },
  );
}
