import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'core_ffi.dart';

final class AndroidCredentialClient {
  AndroidCredentialClient({required this.onCreateReady}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'credentialCreateReady') await onCreateReady();
    });
  }

  static const _channel = MethodChannel(
    'com.ysh0566.getfor/android_credentials',
  );

  final FutureOr<void> Function() onCreateReady;

  Future<bool> syncCredentials(List<VaultItem> records) async {
    return await _channel.invokeMethod<bool>(
          'syncCredentials',
          records
              .map(
                (record) => {
                  'id': record.id,
                  'title': record.title,
                  'website': record.website,
                  'username': record.username,
                  'password': record.password,
                  'passkeys': record.passkeys
                      .map(
                        (passkey) => {
                          'credentialId': _decodeBase64Url(
                            passkey.credentialId,
                          ),
                          'relyingPartyId': passkey.relyingPartyId,
                          'userHandle': _decodeBase64Url(passkey.userHandle),
                          'userName': passkey.userName,
                          'userDisplayName': passkey.userDisplayName,
                          'privateKeyPkcs8': _decodeBase64Url(
                            passkey.privateKeyPkcs8,
                          ),
                          'backupEligible': passkey.backupEligible,
                          'backupState': passkey.backupState,
                        },
                      )
                      .toList(growable: false),
                },
              )
              .toList(growable: false),
        ) ??
        false;
  }

  Future<bool> requestEnable() async {
    return await _channel.invokeMethod<bool>('requestEnable') ?? false;
  }

  Future<void> openBrowserAutoFillSettings() =>
      _channel.invokeMethod<void>('openBrowserAutoFillSettings');

  Future<PendingAndroidCredential?> takePendingCreate() async {
    final value = await _channel.invokeMethod<Map<Object?, Object?>>(
      'takePendingCreate',
    );
    if (value == null) return null;
    return PendingAndroidCredential(
      title: value['title']! as String,
      website: value['website']! as String,
      username: value['username']! as String,
      password: value['password']! as String,
    );
  }

  Future<List<VaultPasskey>> takePendingPasskeys() async {
    final values = await _channel.invokeMethod<List<Object?>>(
      'takePendingPasskeys',
    );
    return (values ?? const [])
        .map((value) {
          final map = value! as Map<Object?, Object?>;
          return VaultPasskey(
            credentialId: _encodeBase64Url(map['credentialId']! as Uint8List),
            relyingPartyId: map['relyingPartyId']! as String,
            userHandle: _encodeBase64Url(map['userHandle']! as Uint8List),
            userName: map['userName']! as String,
            userDisplayName: map['userDisplayName'] as String? ?? '',
            privateKeyPkcs8: _encodeBase64Url(
              map['privateKeyPkcs8']! as Uint8List,
            ),
            backupEligible: map['backupEligible'] as bool? ?? true,
            backupState: map['backupState'] as bool? ?? true,
          );
        })
        .toList(growable: false);
  }

  Future<void> clearPendingPasskeys() =>
      _channel.invokeMethod<void>('clearPendingPasskeys');

  Future<void> completePendingCreate({required bool saved}) async {
    await _channel.invokeMethod<void>('completePendingCreate', {
      'saved': saved,
    });
  }

  void dispose() => _channel.setMethodCallHandler(null);
}

final class PendingAndroidCredential {
  const PendingAndroidCredential({
    required this.title,
    required this.website,
    required this.username,
    required this.password,
  });

  final String title;
  final String website;
  final String username;
  final String password;
}

Uint8List _decodeBase64Url(String value) =>
    Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));

String _encodeBase64Url(Uint8List value) =>
    base64Url.encode(value).replaceAll('=', '');
