import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:getfor/password_tools.dart';

void main() {
  test('generator covers every class and audit finds weak reuse', () {
    final password = generatePassword(length: 20, random: Random(7));
    expect(password, hasLength(20));
    expect(password, matches(RegExp('[a-z]')));
    expect(password, matches(RegExp('[A-Z]')));
    expect(password, matches(RegExp('[0-9]')));
    expect(password, matches(RegExp(r'[^A-Za-z0-9]')));

    final audit = PasswordAudit.fromPasswords([
      'password',
      'GoodPassphrase-42',
      'password',
    ]);
    expect((audit.total, audit.weak, audit.reused), (3, 2, 2));
  });
}
