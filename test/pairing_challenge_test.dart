import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:getfor/pairing_challenge.dart';

void main() {
  test('pairing code is six digits and can only be consumed once', () {
    final challenge = PairingChallenge.create(
      const {'token': 'secret'},
      random: Random(1),
      now: DateTime.utc(2026),
    );

    expect(challenge.code, matches(RegExp(r'^\d{6}$')));
    expect(challenge.consume(challenge.code, now: DateTime.utc(2026)), const {
      'token': 'secret',
    });
    expect(challenge.consume(challenge.code), isNull);
  });

  test('a wrong or expired code is immediately invalid', () {
    final wrong = PairingChallenge.create(
      const {'token': 'secret'},
      random: Random(2),
      now: DateTime.utc(2026),
    );
    expect(wrong.consume('invalid', now: DateTime.utc(2026)), isNull);
    expect(wrong.consume(wrong.code, now: DateTime.utc(2026)), isNull);

    final expired = PairingChallenge.create(
      const {'token': 'secret'},
      random: Random(3),
      now: DateTime.utc(2026),
    );
    expect(
      expired.consume(expired.code, now: DateTime.utc(2026, 1, 1, 0, 3)),
      isNull,
    );
  });
}
