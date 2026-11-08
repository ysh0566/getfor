import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'core_ffi.dart';
import 'totp.dart';

final class CredentialExchangeClient {
  CredentialExchangeClient({required this.onReady}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'credentialExchangeReady') {
        await onReady();
      }
    });
  }

  static const _channel = MethodChannel(
    'com.ysh0566.getfor/credential_exchange',
  );

  final FutureOr<void> Function() onReady;

  Future<CredentialImportBatch?> takePendingImport() async {
    final value = await _channel.invokeMethod<Map<Object?, Object?>>(
      'takePendingImport',
    );
    if (value == null) return null;
    final records = (value['records']! as List<Object?>)
        .map(
          (record) =>
              ImportedVaultItem.fromMap(record! as Map<Object?, Object?>),
        )
        .toList(growable: false);
    return CredentialImportBatch(
      source: value['source']! as String,
      records: records,
      skipped: value['skipped']! as int,
    );
  }

  Future<bool> requestEnableAutoFill() async {
    return await _channel.invokeMethod<bool>('requestEnableAutoFill') ?? false;
  }

  Future<List<VaultPasskey>> takePendingPasskeys() async {
    final values =
        await _channel.invokeMethod<List<Object?>>('takePendingPasskeys') ??
        const [];
    return values
        .map((value) => _passkeyFromPlatform(value! as Map<Object?, Object?>))
        .toList(growable: false);
  }

  Future<void> clearPendingPasskeys() =>
      _channel.invokeMethod<void>('clearPendingPasskeys');

  Future<void> exportItem({
    required String title,
    required String website,
    required String username,
    required String password,
    required String totpSecret,
    required int totpPeriod,
    required int totpDigits,
    required String totpAlgorithm,
    List<VaultPasskey> passkeys = const [],
  }) async {
    await _channel.invokeMethod<void>('exportItem', {
      'title': title,
      'website': website,
      'username': username,
      'password': password,
      if (totpSecret.isNotEmpty) 'totpSecret': decodeBase32(totpSecret),
      'totpPeriod': totpPeriod,
      'totpDigits': totpDigits,
      'totpAlgorithm': totpAlgorithm,
      'passkeys': passkeys.map(_passkeyForPlatform).toList(growable: false),
    });
  }

  Future<bool> syncAutoFill(List<VaultItem> records) async {
    return await _channel.invokeMethod<bool>(
          'syncAutoFill',
          records
              .map(
                (record) => {
                  'id': record.id,
                  'title': record.title,
                  'website': record.website,
                  'username': record.username,
                  'password': record.password,
                  'passkeys': record.passkeys
                      .map(_passkeyForPlatform)
                      .toList(growable: false),
                },
              )
              .toList(growable: false),
        ) ??
        false;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}

final class CredentialImportBatch {
  const CredentialImportBatch({
    required this.source,
    required this.records,
    required this.skipped,
  });

  final String source;
  final List<ImportedVaultItem> records;
  final int skipped;
}

final class ImportedVaultItem {
  const ImportedVaultItem({
    required this.title,
    required this.website,
    required this.username,
    required this.password,
    required this.totpSecret,
    required this.totpPeriod,
    required this.totpDigits,
    required this.totpAlgorithm,
    required this.passkeys,
  });

  factory ImportedVaultItem.fromMap(Map<Object?, Object?> value) {
    final secret = value['totpSecret'] as Uint8List?;
    return ImportedVaultItem(
      title: value['title']! as String,
      website: value['website']! as String,
      username: value['username']! as String,
      password: value['password']! as String,
      totpSecret: secret == null ? '' : encodeBase32(secret),
      totpPeriod: value['totpPeriod']! as int,
      totpDigits: value['totpDigits']! as int,
      totpAlgorithm: value['totpAlgorithm']! as String,
      passkeys: (value['passkeys'] as List<Object?>? ?? const [])
          .map((item) => _passkeyFromPlatform(item! as Map<Object?, Object?>))
          .toList(growable: false),
    );
  }

  final String title;
  final String website;
  final String username;
  final String password;
  final String totpSecret;
  final int totpPeriod;
  final int totpDigits;
  final String totpAlgorithm;
  final List<VaultPasskey> passkeys;
}

Map<String, Object> _passkeyForPlatform(VaultPasskey passkey) => {
  'credentialId': _decodeBase64Url(passkey.credentialId),
  'relyingPartyId': passkey.relyingPartyId,
  'userHandle': _decodeBase64Url(passkey.userHandle),
  'userName': passkey.userName,
  'userDisplayName': passkey.userDisplayName,
  'privateKeyPkcs8': _decodeBase64Url(passkey.privateKeyPkcs8),
  'backupEligible': passkey.backupEligible,
  'backupState': passkey.backupState,
};

VaultPasskey _passkeyFromPlatform(Map<Object?, Object?> value) => VaultPasskey(
  credentialId: _encodeBase64Url(value['credentialId']! as Uint8List),
  relyingPartyId: value['relyingPartyId']! as String,
  userHandle: _encodeBase64Url(value['userHandle']! as Uint8List),
  userName: value['userName']! as String,
  userDisplayName: value['userDisplayName'] as String? ?? '',
  privateKeyPkcs8: _encodeBase64Url(value['privateKeyPkcs8']! as Uint8List),
  backupEligible: value['backupEligible'] as bool? ?? true,
  backupState: value['backupState'] as bool? ?? false,
);

Uint8List _decodeBase64Url(String value) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

String _encodeBase64Url(Uint8List value) =>
    base64Url.encode(value).replaceAll('=', '');

String credentialMatchKey({
  required String title,
  required String website,
  required String username,
}) {
  final normalizedUser = username.trim().toLowerCase();
  final normalizedWebsite = _normalizedWebsite(website);
  final scope = normalizedWebsite.isEmpty
      ? 'title:${title.trim().toLowerCase()}'
      : 'site:$normalizedWebsite';
  return '$scope\u0000$normalizedUser';
}

String _normalizedWebsite(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(candidate);
  var host = uri?.host.toLowerCase() ?? '';
  if (host.startsWith('www.')) host = host.substring(4);
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.isEmpty) return trimmed.toLowerCase().replaceAll(RegExp(r'/+$'), '');
  final port = uri?.hasPort == true ? ':${uri!.port}' : '';
  return '$host$port';
}
