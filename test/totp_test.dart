import 'package:flutter_test/flutter_test.dart';
import 'package:getfor/totp.dart';

void main() {
  test('matches RFC 6238 SHA-1 test vector', () {
    expect(
      generateTotp(
        'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ',
        now: DateTime.fromMillisecondsSinceEpoch(59000, isUtc: true),
        digits: 8,
      ),
      '94287082',
    );
    expect(() => decodeBase32('not!base32'), throwsFormatException);
    expect(
      generateTotp(
        'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA',
        now: DateTime.fromMillisecondsSinceEpoch(59000, isUtc: true),
        digits: 8,
        algorithm: 'sha256',
      ),
      '46119246',
    );
    expect(encodeBase32(decodeBase32('JBSWY3DPEHPK3PXP')), 'JBSWY3DPEHPK3PXP');
  });
}
