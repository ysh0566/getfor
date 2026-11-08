import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'android_credentials.dart';
import 'auto_lock.dart';
import 'core_ffi.dart';
import 'credential_exchange.dart';
import 'lan_sync.dart';
import 'password_tools.dart';
import 'quick_unlock.dart';
import 'totp.dart';
import 'vault_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Getfor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4F46E5),
          secondary: Color(0xFFC0C1FF),
          tertiary: Color(0xFF4EDEA3),
          surface: Color(0xFF122131),
          error: Color(0xFFFFB4AB),
          onSurface: Color(0xFFD4E4FA),
        ),
        scaffoldBackgroundColor: const Color(0xFF051424),
        fontFamily: 'Inter',
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0D1C2D),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0x5545464D)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0x5545464D)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF4F46E5),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        dividerColor: const Color(0x3345464D),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF1C2B3C),
          contentTextStyle: const TextStyle(color: Color(0xFFD4E4FA)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0x3345464D)),
          ),
        ),
        useMaterial3: true,
      ),
      home: const VaultHome(),
    );
  }
}

class VaultHome extends StatefulWidget {
  const VaultHome({super.key});

  @override
  State<VaultHome> createState() => _VaultHomeState();
}

class _VaultHomeState extends State<VaultHome> with WidgetsBindingObserver {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  String? _vaultPath;
  String? _autoLockSettingsPath;
  VaultSession? _session;
  CredentialExchangeClient? _credentialExchange;
  AndroidCredentialClient? _androidCredentials;
  late final LanSyncService _lanSync;
  final _quickUnlock = QuickUnlockClient();
  Timer? _autoLockTimer;
  DateTime? _backgroundedAt;
  List<LanPeer> _lanPeers = const [];
  bool _pairingAllowed = false;
  List<VaultItemSummary> _records = const [];
  PasswordAudit _passwordAudit = const PasswordAudit.empty();
  bool _vaultExists = false;
  bool _loading = true;
  bool _busy = false;
  bool _credentialImportWaiting = false;
  bool _importingCredentials = false;
  bool _androidCredentialWaiting = false;
  bool _savingAndroidCredential = false;
  bool _quickUnlockAvailable = false;
  AutoLockDelay _autoLockDelay = AutoLockDelay.fiveMinutes;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lanSync = LanSyncService(
      onPeersChanged: (peers) {
        if (mounted) setState(() => _lanPeers = peers);
      },
      onVaultChanged: () {
        _reloadRecords();
        unawaited(_syncAutoFillCredentials());
      },
      onPairingCode: (code) => unawaited(_showIncomingPairingCode(code)),
    );
    if (Platform.isMacOS) {
      _credentialExchange = CredentialExchangeClient(
        onReady: _credentialExchangeReady,
      );
    } else if (Platform.isAndroid) {
      _androidCredentials = AndroidCredentialClient(
        onCreateReady: _androidCredentialCreateReady,
      );
    }
    _prepareVault();
  }

  Future<void> _credentialExchangeReady() async {
    if (!mounted) return;
    if (_session == null) {
      setState(() => _credentialImportWaiting = true);
      return;
    }
    await _importPendingCredentials();
  }

  Future<void> _androidCredentialCreateReady() async {
    if (!mounted) return;
    if (_session == null) {
      setState(() => _androidCredentialWaiting = true);
      return;
    }
    await _savePendingAndroidCredential();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resumeFromBackground();
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _scheduleAutoLock();
    } else if (state == AppLifecycleState.detached) {
      // Process teardown always destroys the native key handle, even when background auto-lock is disabled.
      _lock();
    }
  }

  void _scheduleAutoLock() {
    if (_session == null || _backgroundedAt != null) return;
    final delay = _autoLockDelay.duration;
    if (delay == null) return;
    _backgroundedAt = DateTime.now();
    if (delay == Duration.zero) {
      _lock();
      return;
    }
    _autoLockTimer = Timer(delay, _lock);
  }

  void _resumeFromBackground() {
    final backgroundedAt = _backgroundedAt;
    _autoLockTimer?.cancel();
    _autoLockTimer = null;
    _backgroundedAt = null;
    // Mobile timers may be suspended; enforce an elapsed deadline again when the app resumes.
    if (_session != null &&
        backgroundedAt != null &&
        _autoLockDelay.expiredAfter(
          DateTime.now().difference(backgroundedAt),
        )) {
      _lock();
    }
  }

  Future<void> _prepareVault() async {
    try {
      final directory = await getApplicationSupportDirectory();
      await directory.create(recursive: true);
      final path = '${directory.path}${Platform.pathSeparator}vault.db';
      final autoLockSettingsPath =
          '${directory.path}${Platform.pathSeparator}auto_lock_seconds';
      final exists = await File(path).exists();
      final settingsFile = File(autoLockSettingsPath);
      final storedSeconds = await settingsFile.exists()
          ? int.tryParse((await settingsFile.readAsString()).trim())
          : null;
      if (!mounted) return;
      setState(() {
        _vaultPath = path;
        _autoLockSettingsPath = autoLockSettingsPath;
        _autoLockDelay = AutoLockDelay.fromStoredSeconds(storedSeconds);
        _vaultExists = exists;
        _loading = false;
      });
      _quickUnlock.hasKey().then((available) {
        if (mounted) setState(() => _quickUnlockAvailable = available);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '无法准备保险库目录：$error';
        _loading = false;
      });
    }
  }

  void _authenticate() {
    final path = _vaultPath;
    final password = _passwordController.text;
    if (path == null || _busy) return;
    if (!_vaultExists && password.length < 8) {
      setState(() => _error = '主密码至少需要 8 个字符');
      return;
    }
    if (!_vaultExists && password != _confirmController.text) {
      setState(() => _error = '两次输入的主密码不一致');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = _vaultExists
          ? VaultSession.open(path, password)
          : VaultSession.create(path, password);
      final vaultState = _readVaultState(session);
      _passwordController.clear();
      _confirmController.clear();
      setState(() {
        _session = session;
        _records = vaultState.records;
        _passwordAudit = vaultState.audit;
        _vaultExists = true;
      });
      unawaited(_importPendingProviderPasskeys());
      unawaited(_importPendingCredentials());
      unawaited(_savePendingAndroidCredential());
      unawaited(_startLanSync());
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _authenticateQuickly() async {
    final path = _vaultPath;
    if (path == null || _busy) return;
    setState(() => _busy = true);
    try {
      final key = await _quickUnlock.loadKey();
      if (key == null) return;
      final session = VaultSession.openWithKey(path, key);
      key.fillRange(0, key.length, 0);
      final vaultState = _readVaultState(session);
      if (!mounted) return;
      setState(() {
        _session = session;
        _records = vaultState.records;
        _passwordAudit = vaultState.audit;
      });
      unawaited(_importPendingProviderPasskeys());
      unawaited(_importPendingCredentials());
      unawaited(_savePendingAndroidCredential());
      unawaited(_startLanSync());
    } catch (error) {
      _showError('快速解锁失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enableQuickUnlock() async {
    final session = _session;
    if (session == null || _busy) return;
    setState(() => _busy = true);
    try {
      final key = session.quickUnlockKey();
      try {
        await _quickUnlock.saveKey(key);
      } finally {
        key.fillRange(0, key.length, 0);
      }
      if (mounted) {
        setState(() => _quickUnlockAvailable = true);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('设备快速解锁已启用')));
      }
    } catch (error) {
      _showError('无法启用快速解锁：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reloadRecords() {
    final session = _session;
    if (session == null) return;
    try {
      final vaultState = _readVaultState(session);
      setState(() {
        _records = vaultState.records;
        _passwordAudit = vaultState.audit;
      });
    } catch (error) {
      _showError(error);
    }
  }

  ({List<VaultItemSummary> records, PasswordAudit audit}) _readVaultState(
    VaultSession session,
  ) {
    final records = session.listItems();
    final passwords = records
        .where((item) => item.hasPassword)
        .map((item) => session.getItem(item.id).password);
    return (records: records, audit: PasswordAudit.fromPasswords(passwords));
  }

  Future<void> _importPendingCredentials() async {
    final client = _credentialExchange;
    final session = _session;
    if (client == null || session == null || _importingCredentials) return;

    _importingCredentials = true;
    try {
      final batch = await client.takePendingImport();
      if (batch == null) return;
      final existingByKey = <String, List<VaultItem>>{};
      for (final summary in session.listItems()) {
        final existing = session.getItem(summary.id);
        final key = credentialMatchKey(
          title: existing.title,
          website: existing.website,
          username: existing.username,
        );
        existingByKey.putIfAbsent(key, () => []).add(existing);
      }

      final handledCredentials = <String, Set<String>>{};
      var added = 0;
      var updated = 0;
      var duplicates = 0;
      var kept = 0;
      var failed = 0;
      for (final record in batch.records) {
        try {
          final key = credentialMatchKey(
            title: record.title,
            website: record.website,
            username: record.username,
          );
          final candidates = existingByKey[key] ?? const <VaultItem>[];
          final passkeyIds =
              record.passkeys.map((passkey) => passkey.credentialId).toList()
                ..sort();
          final credentialKey = [
            record.password,
            record.totpSecret,
            ...passkeyIds,
          ].join('\u0000');
          final alreadyHandled =
              handledCredentials[key]?.contains(credentialKey) ?? false;
          final exactMatch = candidates.any(
            (existing) =>
                (record.password.isEmpty ||
                    existing.password == record.password) &&
                (record.totpSecret.isEmpty ||
                    existing.totpSecret == record.totpSecret) &&
                record.passkeys.every(
                  (passkey) => existing.passkeys.any(
                    (current) => current.credentialId == passkey.credentialId,
                  ),
                ),
          );
          if (alreadyHandled || exactMatch) {
            duplicates++;
            continue;
          }

          final existing = candidates.isEmpty ? null : candidates.first;
          final hasConflict =
              existing != null &&
              ((record.password.isNotEmpty &&
                      existing.password.isNotEmpty &&
                      record.password != existing.password) ||
                  (record.totpSecret.isNotEmpty &&
                      existing.totpSecret.isNotEmpty &&
                      record.totpSecret != existing.totpSecret));
          final choice = existing == null
              ? _ImportConflictChoice.copy
              : hasConflict
              ? await _resolveImportConflict(record, existing)
              : _ImportConflictChoice.update;
          if (choice == _ImportConflictChoice.keep) {
            kept++;
          } else if (choice == _ImportConflictChoice.update) {
            final target = existing!;
            final mergedPassword = record.password.isEmpty
                ? target.password
                : record.password;
            final mergedTotpSecret = record.totpSecret.isEmpty
                ? target.totpSecret
                : record.totpSecret;
            final mergedPasskeys = <VaultPasskey>[
              ...target.passkeys,
              ...record.passkeys.where(
                (incoming) => !target.passkeys.any(
                  (current) => current.credentialId == incoming.credentialId,
                ),
              ),
            ];
            session.saveItem(
              id: target.id,
              title: record.title,
              website: record.website,
              username: record.username,
              password: mergedPassword,
              totpSecret: mergedTotpSecret,
              totpPeriod: record.totpSecret.isEmpty
                  ? target.totpPeriod
                  : record.totpPeriod,
              totpDigits: record.totpSecret.isEmpty
                  ? target.totpDigits
                  : record.totpDigits,
              totpAlgorithm: record.totpSecret.isEmpty
                  ? target.totpAlgorithm
                  : record.totpAlgorithm,
              passkeys: mergedPasskeys,
            );
            candidates[0] = VaultItem(
              id: target.id,
              title: record.title,
              website: record.website,
              username: record.username,
              password: mergedPassword,
              totpSecret: mergedTotpSecret,
              totpPeriod: record.totpSecret.isEmpty
                  ? target.totpPeriod
                  : record.totpPeriod,
              totpDigits: record.totpSecret.isEmpty
                  ? target.totpDigits
                  : record.totpDigits,
              totpAlgorithm: record.totpSecret.isEmpty
                  ? target.totpAlgorithm
                  : record.totpAlgorithm,
              passkeys: mergedPasskeys,
            );
            updated++;
          } else {
            session.saveItem(
              title: record.title,
              website: record.website,
              username: record.username,
              password: record.password,
              totpSecret: record.totpSecret,
              totpPeriod: record.totpPeriod,
              totpDigits: record.totpDigits,
              totpAlgorithm: record.totpAlgorithm,
              passkeys: record.passkeys,
            );
            added++;
          }
          handledCredentials.putIfAbsent(key, () => {}).add(credentialKey);
        } catch (_) {
          failed++;
        }
      }
      _reloadRecords();
      await _syncAutoFillCredentials();
      if (!mounted) return;
      setState(() => _credentialImportWaiting = false);
      final details = [
        '已从 ${batch.source} 新增 $added 个项目',
        if (updated > 0) '更新 $updated 条',
        if (duplicates > 0) '跳过 $duplicates 条重复项',
        if (kept > 0) '保留 $kept 个现有项目',
        if (batch.skipped > 0) '跳过 ${batch.skipped} 个不支持的项目',
        if (failed > 0) '$failed 条写入失败',
      ].join('，');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(details)));
      if (added + updated > 0) await _offerEnableAutoFill();
    } catch (error) {
      _showError('Credential Exchange 导入失败：$error');
    } finally {
      _importingCredentials = false;
    }
  }

  Future<_ImportConflictChoice> _resolveImportConflict(
    ImportedVaultItem incoming,
    VaultItem existing,
  ) async {
    if (!mounted) return _ImportConflictChoice.keep;
    return await showDialog<_ImportConflictChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('发现同一项目的不同凭据'),
            content: Text(
              '${incoming.website.isEmpty ? incoming.title : incoming.website}\n'
              '用户名：${incoming.username.isEmpty ? "未设置" : incoming.username}\n\n'
              'Getfor 中已有“${existing.title}”，导入项目包含不同的密码或 TOTP。',
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, _ImportConflictChoice.keep),
                child: const Text('保留现有'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, _ImportConflictChoice.copy),
                child: const Text('另存副本'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _ImportConflictChoice.update),
                child: const Text('更新现有'),
              ),
            ],
          ),
        ) ??
        _ImportConflictChoice.keep;
  }

  Future<void> _offerEnableAutoFill() async {
    final macClient = _credentialExchange;
    final androidClient = _androidCredentials;
    if ((macClient == null && androidClient == null) || !mounted) return;
    final enable = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启用 Getfor 自动填充？'),
        content: Text(
          Platform.isMacOS
              ? '启用后，macOS 可以在登录页面从 Getfor 选择凭据。也可以暂不设置。'
              : '1. 在系统自动填充设置中选择 Getfor。\n'
                    '2. 在 Chrome 等浏览器中选择“使用其他自动填充服务”，并按提示重启浏览器。\n'
                    '3. 返回 Getfor 解锁保险库，使凭据同步到自动填充。\n\n'
                    '填充时需要使用指纹或设备屏幕锁验证身份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('暂不'),
          ),
          if (androidClient != null)
            TextButton(
              onPressed: () => Navigator.pop(context, 'browser'),
              child: const Text('浏览器设置'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'system'),
            child: Text(androidClient != null ? '系统设置' : '设为默认'),
          ),
        ],
      ),
    );
    if (enable == null || !mounted) return;
    try {
      if (enable == 'browser') {
        await androidClient!.openBrowserAutoFillSettings();
        return;
      }
      final enabled = macClient != null
          ? await macClient.requestEnableAutoFill()
          : await androidClient!.requestEnable();
      if (!mounted) return;
      if (enabled) await _syncAutoFillCredentials(showErrors: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            enabled
                ? (Platform.isAndroid ? '已打开系统自动填充设置' : 'Getfor 自动填充已启用')
                : '未启用 Getfor 自动填充',
          ),
        ),
      );
    } catch (error) {
      _showError('无法启用自动填充：$error');
    }
  }

  Future<void> _syncAutoFillCredentials({bool showErrors = false}) async {
    final macClient = _credentialExchange;
    final androidClient = _androidCredentials;
    final session = _session;
    if ((macClient == null && androidClient == null) || session == null) return;
    try {
      final records = <VaultItem>[];
      for (final summary in session.listItems()) {
        if (!summary.hasPassword && !summary.hasPasskey) continue;
        records.add(session.getItem(summary.id));
      }
      if (macClient != null) await macClient.syncAutoFill(records);
      if (androidClient != null) {
        await androidClient.syncCredentials(records);
      }
    } catch (error) {
      if (showErrors) _showError('无法更新自动填充：$error');
    }
  }

  Future<void> _savePendingAndroidCredential() async {
    final client = _androidCredentials;
    if (client == null || _session == null || _savingAndroidCredential) return;
    _savingAndroidCredential = true;
    try {
      final pending = await client.takePendingCreate();
      if (pending == null) return;
      if (mounted) setState(() => _androidCredentialWaiting = false);
      final saved = await _editRecord(
        initialTitle: pending.title,
        initialWebsite: pending.website,
        initialUsername: pending.username,
        initialPassword: pending.password,
      );
      await client.completePendingCreate(saved: saved);
    } catch (error) {
      _showError('无法保存 Android 密码：$error');
      await client.completePendingCreate(saved: false);
    } finally {
      _savingAndroidCredential = false;
    }
  }

  Future<void> _importPendingProviderPasskeys() async {
    final androidClient = _androidCredentials;
    final macClient = _credentialExchange;
    final session = _session;
    if ((androidClient == null && macClient == null) || session == null) {
      await _syncAutoFillCredentials();
      return;
    }
    try {
      final pending = androidClient != null
          ? await androidClient.takePendingPasskeys()
          : await macClient!.takePendingPasskeys();
      if (pending.isEmpty) {
        await _syncAutoFillCredentials();
        return;
      }
      final records = session
          .listItems()
          .map((item) => session.getItem(item.id))
          .toList();
      final knownIds = records
          .expand((record) => record.passkeys)
          .map((passkey) => passkey.credentialId)
          .toSet();
      var imported = 0;
      for (final passkey in pending) {
        if (!knownIds.add(passkey.credentialId)) continue;
        final matching = records.where(
          (record) =>
              record.passkeys.any(
                (current) =>
                    current.relyingPartyId == passkey.relyingPartyId &&
                    current.userName == passkey.userName,
              ) ||
              (record.username == passkey.userName &&
                  Uri.tryParse(
                        record.website.contains('://')
                            ? record.website
                            : 'https://${record.website}',
                      )?.host.toLowerCase() ==
                      passkey.relyingPartyId),
        );
        final target = matching.isEmpty ? null : matching.first;
        if (target == null) {
          session.saveItem(
            title: passkey.relyingPartyId,
            website: 'https://${passkey.relyingPartyId}',
            username: passkey.userName,
            password: '',
            totpSecret: '',
            passkeys: [passkey],
          );
          records.add(
            session
                .listItems()
                .map((item) => session.getItem(item.id))
                .firstWhere(
                  (record) => record.passkeys.any(
                    (current) => current.credentialId == passkey.credentialId,
                  ),
                ),
          );
        } else {
          final updated = VaultItem(
            id: target.id,
            title: target.title,
            website: target.website,
            username: target.username,
            password: target.password,
            totpSecret: target.totpSecret,
            totpPeriod: target.totpPeriod,
            totpDigits: target.totpDigits,
            totpAlgorithm: target.totpAlgorithm,
            passkeys: [...target.passkeys, passkey],
          );
          session.saveItem(
            id: updated.id,
            title: updated.title,
            website: updated.website,
            username: updated.username,
            password: updated.password,
            totpSecret: updated.totpSecret,
            totpPeriod: updated.totpPeriod,
            totpDigits: updated.totpDigits,
            totpAlgorithm: updated.totpAlgorithm,
            passkeys: updated.passkeys,
          );
          records[records.indexOf(target)] = updated;
        }
        imported++;
      }
      if (androidClient != null) {
        await androidClient.clearPendingPasskeys();
      } else {
        await macClient!.clearPendingPasskeys();
      }
      _reloadRecords();
      await _syncAutoFillCredentials();
      if (imported > 0 && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已保存 $imported 个通行密钥到保险库')));
      }
    } catch (error) {
      _showError('无法保存通行密钥：$error');
    }
  }

  Future<void> _showCredentialImportHelp() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从 Apple 密码导入'),
        content: const Text(
          '请在 Apple 密码的迁移或导出功能中选择 Getfor 作为目标。'
          '系统完成本地认证后会打开 Getfor，并将选中的密码、TOTP 与通行密钥写入当前保险库。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _startLanSync() async {
    final session = _session;
    if (session == null) return;
    try {
      await _lanSync.start(session);
      if (mounted) setState(() => _pairingAllowed = _lanSync.pairingAllowed);
    } catch (error) {
      _showError('无法启动局域网同步：$error');
    }
  }

  Future<void> _setPairingAllowed(bool allowed) async {
    try {
      await _lanSync.setPairingAllowed(allowed);
      if (mounted) setState(() => _pairingAllowed = allowed);
    } catch (error) {
      _showError('无法修改配对设置：$error');
    }
  }

  Future<void> _setAutoLockDelay(AutoLockDelay delay) async {
    final path = _autoLockSettingsPath;
    if (path == null) return;
    try {
      await File(path).writeAsString('${delay.storedSeconds}', flush: true);
      if (mounted) setState(() => _autoLockDelay = delay);
    } catch (error) {
      _showError('无法保存自动锁定设置：$error');
    }
  }

  Future<void> _showIncomingPairingCode(String code) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新设备请求配对'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('请在请求配对的设备上输入此验证码：'),
            const SizedBox(height: 18),
            SelectableText(
              code,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 36,
                fontWeight: FontWeight.w700,
                letterSpacing: 8,
              ),
            ),
            const SizedBox(height: 12),
            const Text('验证码 2 分钟内有效，且只能尝试一次。'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _pairDevice(LanPeer peer) async {
    String requestId;
    try {
      requestId = await _lanSync.requestPairing(peer);
    } catch (error) {
      _showError('无法请求配对：$error');
      return;
    }
    if (!mounted) return;

    final code = TextEditingController();
    final password = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('输入配对验证码'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: code,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(labelText: '对方显示的 6 位验证码'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '本机主密码'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: code.text.length == 6
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('配对'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) {
      code.dispose();
      password.dispose();
      return;
    }
    try {
      final imported = await _lanSync.confirmPairing(
        peer,
        requestId,
        code.text,
        password.text,
      );
      if (_quickUnlockAvailable) await _enableQuickUnlock();
      _reloadRecords();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('配对完成，接收 $imported 条变更')));
      }
    } catch (error) {
      _showError('配对失败：$error');
    } finally {
      code.clear();
      password.clear();
      code.dispose();
      password.dispose();
    }
  }

  Future<void> _syncDevice(LanPeer peer) async {
    try {
      final imported = await _lanSync.sync(peer);
      _reloadRecords();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(imported == 0 ? '已经是最新状态' : '已接收 $imported 条变更'),
          ),
        );
      }
    } catch (error) {
      _showError('同步失败：$error');
    }
  }

  Future<bool> _editRecord({
    VaultItemSummary? summary,
    String initialTitle = '',
    String initialWebsite = '',
    String initialUsername = '',
    String initialPassword = '',
  }) async {
    final session = _session;
    if (session == null || _busy) return false;

    VaultItem? item;
    if (summary != null) {
      setState(() => _busy = true);
      try {
        item = session.getItem(summary.id);
      } catch (error) {
        _showError(error);
        return false;
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    if (!mounted) return false;

    final draft = await showDialog<_ItemDraft>(
      context: context,
      builder: (context) => _ItemDialog(
        item: item,
        initialTitle: initialTitle,
        initialWebsite: initialWebsite,
        initialUsername: initialUsername,
        initialPassword: initialPassword,
      ),
    );
    if (draft == null || !mounted) return false;

    var saved = false;
    setState(() => _busy = true);
    try {
      session.saveItem(
        id: item?.id,
        title: draft.title,
        website: draft.website,
        username: draft.username,
        password: draft.password,
        totpSecret: draft.totpSecret,
        totpPeriod: draft.totpPeriod,
        totpDigits: draft.totpDigits,
        totpAlgorithm: draft.totpAlgorithm,
        passkeys: item?.passkeys ?? const [],
      );
      _reloadRecords();
      unawaited(_syncAutoFillCredentials());
      saved = true;
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (saved && summary == null && draft.exportToApple) {
      await _exportItemToApple(draft);
    }
    return saved;
  }

  Future<void> _showPasswordGenerator() async {
    final password = await showDialog<String>(
      context: context,
      builder: (context) => const _PasswordGeneratorDialog(),
    );
    if (password != null && mounted) {
      await _editRecord(initialPassword: password);
    }
  }

  Future<void> _changeMasterPassword() async {
    final session = _session;
    if (session == null || _busy) return;
    final draft = await showDialog<_PasswordChangeDraft>(
      context: context,
      builder: (context) => const _ChangePasswordDialog(),
    );
    if (draft == null || !mounted) return;

    setState(() => _busy = true);
    try {
      session.changePassword(draft.currentPassword, draft.newPassword);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('主密码已修改')));
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportItemToApple(_ItemDraft draft) async {
    final client = _credentialExchange;
    if (client == null) return;
    while (mounted) {
      try {
        await client.exportItem(
          title: draft.title,
          website: draft.website,
          username: draft.username,
          password: draft.password,
          totpSecret: draft.totpSecret,
          totpPeriod: draft.totpPeriod,
          totpDigits: draft.totpDigits,
          totpAlgorithm: draft.totpAlgorithm,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('系统导出流程已完成')));
        return;
      } catch (error) {
        if (!mounted) return;
        final retry = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('未完成导出'),
            content: Text('项目已安全保存在 Getfor。\n\n$error'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('稍后'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('重试'),
              ),
            ],
          ),
        );
        if (retry != true) return;
      }
    }
  }

  Future<void> _deleteItem(VaultItemSummary item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除项目'),
        content: Text('确定删除“${item.title}”吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      _session?.deleteItem(item.id);
      _reloadRecords();
      unawaited(_syncAutoFillCredentials());
    } catch (error) {
      _showError(error);
    }
  }

  void _lock() {
    _autoLockTimer?.cancel();
    _autoLockTimer = null;
    _backgroundedAt = null;
    final session = _session;
    if (session == null) return;
    try {
      unawaited(_lanSync.stop());
      session.lock();
      if (mounted) {
        setState(() {
          _session = null;
          _records = const [];
          _passwordAudit = const PasswordAudit.empty();
          _lanPeers = const [];
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _credentialExchange?.dispose();
    _androidCredentials?.dispose();
    unawaited(_lanSync.stop());
    _autoLockTimer?.cancel();
    try {
      _session?.lock();
    } catch (_) {
      // Process teardown will release the native handle if it already became invalid.
    }
    _passwordController.clear();
    _confirmController.clear();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_session == null) return _buildAuthentication();
    return _buildRecords();
  }

  Widget _buildAuthentication() {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.35, -0.45),
            radius: 1.2,
            colors: [Color(0xFF16254A), Color(0xFF051424)],
          ),
        ),
        child: Center(
          child: Container(
            width: 430,
            padding: const EdgeInsets.all(34),
            decoration: BoxDecoration(
              color: const Color(0xCC0D1C2D),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x334F5F78)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x66010F1F),
                  blurRadius: 48,
                  offset: Offset(0, 24),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C2B3C),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0x554EDEA3)),
                  ),
                  child: Icon(
                    _vaultExists ? Icons.lock_outline : Icons.key,
                    size: 28,
                    color: const Color(0xFF4EDEA3),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  _vaultExists ? '解锁 Getfor' : '创建 Getfor 保险库',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '你的凭据仅保存在受保护的本地保险库中',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFC6C6CD)),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '主密码',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _vaultExists ? _authenticate() : null,
                ),
                if (!_vaultExists) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _confirmController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '确认主密码',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _authenticate(),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (_credentialImportWaiting) ...[
                  const SizedBox(height: 12),
                  const Text('已收到 Credential Exchange 数据，请解锁保险库以完成导入。'),
                ],
                if (_androidCredentialWaiting) ...[
                  const SizedBox(height: 12),
                  const Text('Android 正在等待保存密码，请解锁保险库继续。'),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _authenticate,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(_vaultExists ? '解锁' : '创建保险库'),
                  ),
                ),
                if (_vaultExists && _quickUnlockAvailable) ...[
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: _busy ? null : _authenticateQuickly,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('使用设备快速解锁'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecords() {
    final session = _session!;
    return VaultShell(
      records: _records,
      passwordAudit: _passwordAudit,
      loadItem: session.getItem,
      onAdd: () => unawaited(_editRecord()),
      onGeneratePassword: () => unawaited(_showPasswordGenerator()),
      onEdit: (item) => unawaited(_editRecord(summary: item)),
      onDelete: (item) => unawaited(_deleteItem(item)),
      onImport: () => unawaited(_showCredentialImportHelp()),
      onEnableAutoFill: () => unawaited(_offerEnableAutoFill()),
      onChangeMasterPassword: () => unawaited(_changeMasterPassword()),
      onEnableQuickUnlock: () => unawaited(_enableQuickUnlock()),
      quickUnlockAvailable: _quickUnlockAvailable,
      autoLockDelay: _autoLockDelay,
      onAutoLockDelayChanged: (delay) => unawaited(_setAutoLockDelay(delay)),
      lanPeers: _lanPeers,
      pairingAllowed: _pairingAllowed,
      onPairingAllowedChanged: (allowed) =>
          unawaited(_setPairingAllowed(allowed)),
      onPairDevice: (peer) => unawaited(_pairDevice(peer)),
      onSyncDevice: (peer) => unawaited(_syncDevice(peer)),
      onRevokeDevice: (peer) => unawaited(_lanSync.revoke(peer.id)),
      onLock: _lock,
      busy: _busy,
    );
  }
}

enum _ImportConflictChoice { keep, update, copy }

final class _ItemDraft {
  const _ItemDraft({
    required this.title,
    required this.website,
    required this.username,
    required this.password,
    required this.totpSecret,
    required this.totpPeriod,
    required this.totpDigits,
    required this.totpAlgorithm,
    required this.exportToApple,
  });

  final String title;
  final String website;
  final String username;
  final String password;
  final String totpSecret;
  final int totpPeriod;
  final int totpDigits;
  final String totpAlgorithm;
  final bool exportToApple;
}

class _ItemDialog extends StatefulWidget {
  const _ItemDialog({
    required this.initialTitle,
    required this.initialWebsite,
    required this.initialUsername,
    required this.initialPassword,
    this.item,
  });

  final VaultItem? item;
  final String initialTitle;
  final String initialWebsite;
  final String initialUsername;
  final String initialPassword;

  @override
  State<_ItemDialog> createState() => _ItemDialogState();
}

class _ItemDialogState extends State<_ItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _website;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _totpSecret;
  bool _showPassword = false;
  bool _showTotpSecret = false;
  late bool _exportToApple;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _title = TextEditingController(text: item?.title ?? widget.initialTitle);
    _website = TextEditingController(
      text: item?.website ?? widget.initialWebsite,
    );
    _username = TextEditingController(
      text: item?.username ?? widget.initialUsername,
    );
    _password = TextEditingController(
      text: item?.password ?? widget.initialPassword,
    );
    _totpSecret = TextEditingController(text: item?.totpSecret);
    _exportToApple = item == null && Platform.isMacOS;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _ItemDraft(
        title: _title.text,
        website: _website.text,
        username: _username.text,
        password: _password.text,
        totpSecret: normalizeTotpSecret(_totpSecret.text),
        totpPeriod: widget.item?.totpPeriod ?? 30,
        totpDigits: widget.item?.totpDigits ?? 6,
        totpAlgorithm: widget.item?.totpAlgorithm ?? 'sha1',
        exportToApple: _exportToApple,
      ),
    );
  }

  @override
  void dispose() {
    _title.clear();
    _website.clear();
    _username.clear();
    _password.clear();
    _totpSecret.clear();
    _title.dispose();
    _website.dispose();
    _username.dispose();
    _password.dispose();
    _totpSecret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? '新建项目' : '编辑项目'),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _title,
                  autofocus: true,
                  maxLength: 512,
                  decoration: const InputDecoration(labelText: '网站或 App'),
                  validator: (value) =>
                      value == null || value.isEmpty ? '请输入网站或 App 名称' : null,
                ),
                TextFormField(
                  controller: _website,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: '网址（可选）'),
                ),
                const SizedBox(height: 8),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('登录凭据（可选）'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _username,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                TextFormField(
                  controller: _password,
                  obscureText: !_showPassword,
                  decoration: InputDecoration(
                    labelText: '密码',
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '生成安全密码',
                          onPressed: () => setState(() {
                            _password.text = generatePassword();
                            _showPassword = true;
                          }),
                          icon: const Icon(Icons.password_outlined),
                        ),
                        IconButton(
                          tooltip: _showPassword ? '隐藏密码' : '显示密码',
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                      ],
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (_password.text.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '强度：${switch (passwordStrength(_password.text)) {
                        PasswordStrength.weak => "弱",
                        PasswordStrength.fair => "中等",
                        PasswordStrength.strong => "强",
                      }}',
                      style: TextStyle(
                        color:
                            passwordStrength(_password.text) ==
                                PasswordStrength.strong
                            ? const Color(0xFF4EDEA3)
                            : const Color(0xFFFFC857),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('TOTP 凭据（可选）'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _totpSecret,
                  obscureText: !_showTotpSecret,
                  decoration: InputDecoration(
                    labelText: 'Base32 密钥',
                    suffixIcon: IconButton(
                      tooltip: _showTotpSecret ? '隐藏密钥' : '显示密钥',
                      onPressed: () =>
                          setState(() => _showTotpSecret = !_showTotpSecret),
                      icon: Icon(
                        _showTotpSecret
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                    ),
                  ),
                  validator: (value) {
                    if ((value == null || value.isEmpty) &&
                        _password.text.isEmpty) {
                      return '请至少填写密码或 TOTP 密钥';
                    }
                    if (value != null && value.isNotEmpty) {
                      try {
                        decodeBase32(value);
                      } on FormatException catch (error) {
                        return error.message.toString();
                      }
                    }
                    return null;
                  },
                  onFieldSubmitted: (_) => _save(),
                ),
                if (widget.item == null && Platform.isMacOS)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _exportToApple,
                    onChanged: (value) =>
                        setState(() => _exportToApple = value ?? false),
                    title: const Text('保存后导出到 Apple 密码'),
                    subtitle: const Text('下一步需要在系统界面选择 Apple 密码'),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

final class _PasswordChangeDraft {
  const _PasswordChangeDraft({
    required this.currentPassword,
    required this.newPassword,
  });

  final String currentPassword;
  final String newPassword;
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _replacement = TextEditingController();
  final _confirmation = TextEditingController();

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _PasswordChangeDraft(
        currentPassword: _current.text,
        newPassword: _replacement.text,
      ),
    );
  }

  @override
  void dispose() {
    _current.clear();
    _replacement.clear();
    _confirmation.clear();
    _current.dispose();
    _replacement.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改主密码'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _current,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(labelText: '当前主密码'),
                validator: (value) =>
                    value == null || value.isEmpty ? '请输入当前主密码' : null,
              ),
              TextFormField(
                controller: _replacement,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新主密码'),
                validator: (value) =>
                    value == null || value.length < 8 ? '新主密码至少需要 8 个字符' : null,
              ),
              TextFormField(
                controller: _confirmation,
                obscureText: true,
                decoration: const InputDecoration(labelText: '确认新主密码'),
                validator: (value) =>
                    value != _replacement.text ? '两次输入的新主密码不一致' : null,
                onFieldSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 12),
              const Text(
                '修改后旧主密码将立即失效。Getfor 无法恢复遗失的主密码。',
                style: TextStyle(color: Color(0xFFC6C6CD)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('修改')),
      ],
    );
  }
}

class _PasswordGeneratorDialog extends StatefulWidget {
  const _PasswordGeneratorDialog();

  @override
  State<_PasswordGeneratorDialog> createState() =>
      _PasswordGeneratorDialogState();
}

class _PasswordGeneratorDialogState extends State<_PasswordGeneratorDialog> {
  int _length = 20;
  late String _password;
  Timer? _clipboardTimer;

  @override
  void initState() {
    super.initState();
    _password = generatePassword(length: _length);
  }

  void _regenerate() {
    setState(() => _password = generatePassword(length: _length));
  }

  Future<void> _copy() async {
    final copied = _password;
    await Clipboard.setData(ClipboardData(text: copied));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('密码已复制，30 秒后自动清除')));
    _clipboardTimer?.cancel();
    _clipboardTimer = Timer(const Duration(seconds: 30), () async {
      final current = await Clipboard.getData(Clipboard.kTextPlain);
      if (current?.text == copied) {
        await Clipboard.setData(const ClipboardData(text: ''));
      }
    });
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('生成安全密码'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: SelectableText(_password)),
                IconButton(
                  tooltip: '复制密码',
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text('长度：$_length'),
            Slider(
              value: _length.toDouble(),
              min: 12,
              max: 40,
              divisions: 28,
              onChanged: (value) {
                _length = value.round();
                _regenerate();
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _regenerate,
          icon: const Icon(Icons.refresh),
          label: const Text('重新生成'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _password),
          child: const Text('用于新项目'),
        ),
      ],
    );
  }
}
