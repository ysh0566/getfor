import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getfor/auto_lock.dart';
import 'package:getfor/core_ffi.dart';
import 'package:getfor/password_tools.dart';
import 'package:getfor/lan_sync.dart';
import 'package:getfor/vault_shell.dart';

void main() {
  testWidgets('desktop shell keeps vault data and placeholder pages reachable', (
    tester,
  ) async {
    var pairingAllowed = false;
    var autoLockDelay = AutoLockDelay.fiveMinutes;
    await tester.binding.setSurfaceSize(const Size(1280, 1024));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const summary = VaultItemSummary(
      id: 'record-1',
      title: 'GitHub - Work',
      website: 'github.com',
      username: 'johndoe_dev',
      hasPassword: true,
      hasTotp: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VaultShell(
          records: const [summary],
          passwordAudit: const PasswordAudit(total: 1, weak: 0, reused: 0),
          loadItem: (_) => const VaultItem(
            id: 'record-1',
            title: 'GitHub - Work',
            website: 'github.com',
            username: 'johndoe_dev',
            password: 'secret',
            totpSecret: 'JBSWY3DPEHPK3PXP',
          ),
          onAdd: () {},
          onGeneratePassword: () {},
          onEdit: (_) {},
          onDelete: (_) {},
          onImport: () {},
          onEnableAutoFill: () {},
          onChangeMasterPassword: () {},
          onEnableQuickUnlock: () {},
          quickUnlockAvailable: true,
          autoLockDelay: autoLockDelay,
          onAutoLockDelayChanged: (delay) => autoLockDelay = delay,
          lanPeers: const <LanPeer>[],
          pairingAllowed: false,
          onPairingAllowedChanged: (allowed) => pairingAllowed = allowed,
          onPairDevice: (_) {},
          onSyncDevice: (_) {},
          onRevokeDevice: (_) {},
          onLock: () {},
          busy: false,
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(940, 1024));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(1280, 1024));
    await tester.pumpAndSettle();
    expect(find.text('GitHub - Work'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('TOTP'), findsOneWidget);
    await tester.tap(find.text('GitHub - Work'));
    await tester.pumpAndSettle();
    // Resizing through tablet orientations must preserve both selection and list.
    for (final size in const [
      Size(700, 1024),
      Size(834, 1194),
      Size(909, 1363),
      Size(1194, 834),
      Size(1363, 909),
    ]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('返回保险库'), findsNothing);
      expect(find.text('GitHub - Work'), findsNWidgets(2));
      expect(find.text('用户名'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('GitHub - Work').last).dx,
        greaterThan(tester.getTopLeft(find.text('GitHub - Work').first).dx),
      );
      expect(tester.takeException(), isNull);
      for (final icon in const [
        Icons.dashboard_outlined,
        Icons.security_outlined,
        Icons.share_outlined,
        Icons.settings_outlined,
      ]) {
        await tester.tap(find.byIcon(icon).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byIcon(Icons.lock_outline).first);
      await tester.pumpAndSettle();
    }
    await tester.binding.setSurfaceSize(const Size(1280, 1024));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安全中心'));
    await tester.pumpAndSettle();
    expect(find.text('安全健康检查'), findsOneWidget);
    expect(find.text('弱密码'), findsOneWidget);
    expect(find.text('复用密码条目'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('已启用，可使用系统生物识别或屏幕锁'), findsOneWidget);
    expect(find.text('重新启用'), findsOneWidget);
    expect(find.text('自动锁定'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<AutoLockDelay>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('15 分钟').last);
    await tester.pumpAndSettle();
    expect(autoLockDelay, AutoLockDelay.fifteenMinutes);
    expect(find.text('允许配对'), findsOneWidget);
    expect(find.text('已关闭，本机不会出现在设备搜索结果中'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    expect(pairingAllowed, isTrue);
  });

  testWidgets('phone shell uses bottom navigation without overflow', (
    tester,
  ) async {
    const summary = VaultItemSummary(
      id: 'mobile-record',
      title: 'GitHub',
      website: 'github.com',
      username: 'mobile-user',
      hasPassword: true,
      hasTotp: true,
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: VaultShell(
          records: const [summary],
          passwordAudit: const PasswordAudit(total: 1, weak: 0, reused: 0),
          loadItem: (_) => const VaultItem(
            id: 'mobile-record',
            title: 'GitHub',
            website: 'github.com',
            username: 'mobile-user',
            password: 'secret',
            totpSecret: 'JBSWY3DPEHPK3PXP',
          ),
          onAdd: () {},
          onGeneratePassword: () {},
          onEdit: (_) {},
          onDelete: (_) {},
          onImport: () {},
          onEnableAutoFill: () {},
          onChangeMasterPassword: () {},
          onEnableQuickUnlock: () {},
          quickUnlockAvailable: true,
          autoLockDelay: AutoLockDelay.fiveMinutes,
          onAutoLockDelayChanged: (_) {},
          lanPeers: const <LanPeer>[],
          pairingAllowed: false,
          onPairingAllowedChanged: (_) {},
          onPairDevice: (_) {},
          onSyncDevice: (_) {},
          onRevokeDevice: (_) {},
          onLock: () {},
          busy: false,
        ),
      ),
    );

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byIcon(Icons.lock_outline),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('搜索保险库…'), findsOneWidget);
    await tester.tap(find.text('GitHub'));
    await tester.pumpAndSettle();
    expect(find.text('返回保险库'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.security_outlined));
    await tester.pumpAndSettle();
    expect(find.text('安全健康检查'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.sync_outlined));
    await tester.pumpAndSettle();
    expect(find.text('同一局域网设备'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(find.text('允许配对'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
