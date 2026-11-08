import 'package:flutter_test/flutter_test.dart';
import 'package:getfor/credential_exchange.dart';

void main() {
  test('credential match key normalizes website and username', () {
    final imported = credentialMatchKey(
      title: 'GitHub',
      website: 'https://www.GitHub.com/login/',
      username: ' Alice ',
    );
    final existing = credentialMatchKey(
      title: 'Work GitHub',
      website: 'github.com',
      username: 'alice',
    );

    expect(imported, existing);
  });

  test('empty websites fall back to normalized title', () {
    expect(
      credentialMatchKey(title: ' Local App ', website: '', username: 'User'),
      credentialMatchKey(title: 'local app', website: '', username: 'user'),
    );
  });
}
