import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

String normalizeTotpSecret(String value) =>
    value.replaceAll(RegExp(r'[\s-]'), '').replaceAll('=', '').toUpperCase();

Uint8List decodeBase32(String value) {
  final input = normalizeTotpSecret(value);
  if (input.isEmpty) throw const FormatException('TOTP 密钥不能为空');

  var buffer = 0;
  var bits = 0;
  final bytes = <int>[];
  for (final codeUnit in input.codeUnits) {
    final digit = _base32Alphabet.indexOf(String.fromCharCode(codeUnit));
    if (digit < 0) throw const FormatException('TOTP 密钥不是有效的 Base32');
    buffer = (buffer << 5) | digit;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.add((buffer >> bits) & 0xff);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bytes.isEmpty) throw const FormatException('TOTP 密钥太短');
  return Uint8List.fromList(bytes);
}

String encodeBase32(Uint8List bytes) {
  var buffer = 0;
  var bits = 0;
  final output = StringBuffer();
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      output.write(_base32Alphabet[(buffer >> bits) & 0x1f]);
      buffer &= (1 << bits) - 1;
    }
  }
  if (bits > 0) output.write(_base32Alphabet[(buffer << (5 - bits)) & 0x1f]);
  return output.toString();
}

String generateTotp(
  String secret, {
  DateTime? now,
  int period = 30,
  int digits = 6,
  String algorithm = 'sha1',
}) {
  if (period <= 0 || digits < 6 || digits > 8) {
    throw const FormatException('无效的 TOTP 参数');
  }
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  final counter = seconds ~/ period;
  final counterBytes = Uint8List(8);
  ByteData.sublistView(counterBytes).setUint64(0, counter, Endian.big);
  final hash = switch (algorithm) {
    'sha1' => sha1,
    'sha256' => sha256,
    'sha512' => sha512,
    _ => throw const FormatException('不支持的 TOTP 算法'),
  };
  final digest = Hmac(hash, decodeBase32(secret)).convert(counterBytes).bytes;

  // RFC 4226 dynamic truncation selects four bytes from the HMAC digest.
  final offset = digest.last & 0x0f;
  final binary =
      ((digest[offset] & 0x7f) << 24) |
      ((digest[offset + 1] & 0xff) << 16) |
      ((digest[offset + 2] & 0xff) << 8) |
      (digest[offset + 3] & 0xff);
  final modulus = switch (digits) {
    6 => 1000000,
    7 => 10000000,
    _ => 100000000,
  };
  return (binary % modulus).toString().padLeft(digits, '0');
}

int totpRemainingSeconds({DateTime? now, int period = 30}) {
  final seconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
  return period - (seconds % period);
}
