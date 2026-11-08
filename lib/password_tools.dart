import 'dart:math';

const _lower = 'abcdefghijkmnopqrstuvwxyz';
const _upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const _digits = '23456789';
const _symbols = '!@#%&*+-=?';
const _commonPasswords = {
  '123456',
  'password',
  'qwerty',
  'letmein',
  'admin',
  'welcome',
};

enum PasswordStrength { weak, fair, strong }

PasswordStrength passwordStrength(String password) {
  final classes = [
    RegExp('[a-z]'),
    RegExp('[A-Z]'),
    RegExp('[0-9]'),
    RegExp(r'[^A-Za-z0-9]'),
  ].where((pattern) => pattern.hasMatch(password)).length;
  if (password.length < 12 ||
      classes < 3 ||
      _commonPasswords.contains(password.toLowerCase())) {
    return PasswordStrength.weak;
  }
  return password.length >= 16 && classes == 4
      ? PasswordStrength.strong
      : PasswordStrength.fair;
}

String generatePassword({int length = 20, Random? random}) {
  if (length < 12 || length > 128) {
    throw const FormatException('密码长度必须在 12 到 128 之间');
  }
  final source = random ?? Random.secure();
  final classes = [_lower, _upper, _digits, _symbols];
  final characters = [
    // Each class is inserted before shuffling so a generated password cannot omit one by chance.
    for (final values in classes) values[source.nextInt(values.length)],
  ];
  final alphabet = classes.join();
  while (characters.length < length) {
    characters.add(alphabet[source.nextInt(alphabet.length)]);
  }
  for (var index = characters.length - 1; index > 0; index--) {
    final swap = source.nextInt(index + 1);
    final value = characters[index];
    characters[index] = characters[swap];
    characters[swap] = value;
  }
  return characters.join();
}

final class PasswordAudit {
  const PasswordAudit({
    required this.total,
    required this.weak,
    required this.reused,
  });

  const PasswordAudit.empty() : total = 0, weak = 0, reused = 0;

  factory PasswordAudit.fromPasswords(Iterable<String> passwords) {
    final values = passwords.where((password) => password.isNotEmpty).toList();
    final counts = <String, int>{};
    for (final password in values) {
      counts.update(password, (count) => count + 1, ifAbsent: () => 1);
    }
    return PasswordAudit(
      total: values.length,
      weak: values
          .where(
            (password) => passwordStrength(password) == PasswordStrength.weak,
          )
          .length,
      reused: values.where((password) => counts[password]! > 1).length,
    );
  }

  final int total;
  final int weak;
  final int reused;

  int get score {
    if (total == 0) return 100;
    final deductions = ((weak + reused) * 100 / total).round();
    return (100 - deductions).clamp(0, 100);
  }
}
