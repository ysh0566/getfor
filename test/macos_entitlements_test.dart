import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('macOS runner can host and connect to LAN sync peers', () {
    if (!Platform.isMacOS) return;

    for (final file in [
      'macos/Runner/DebugProfile.entitlements',
      'macos/Runner/Release.entitlements',
    ]) {
      for (final entitlement in [
        'com.apple.security.network.server',
        'com.apple.security.network.client',
      ]) {
        final result = Process.runSync('/usr/bin/plutil', [
          '-extract',
          entitlement.replaceAll('.', r'\.'),
          'raw',
          file,
        ]);
        expect(
          result.stdout.toString().trim(),
          'true',
          reason: '$file 缺少 $entitlement',
        );
      }
    }

    final usage = Process.runSync('/usr/bin/plutil', [
      '-extract',
      'NSLocalNetworkUsageDescription',
      'raw',
      'macos/Runner/Info.plist',
    ]);
    expect(usage.stdout.toString().trim(), isNotEmpty);
    final service = Process.runSync('/usr/bin/plutil', [
      '-extract',
      'NSBonjourServices.0',
      'raw',
      'macos/Runner/Info.plist',
    ]);
    expect(service.stdout.toString().trim(), '_getfor._tcp');
  });
}
