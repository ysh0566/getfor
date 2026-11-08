import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class GetforVault extends Opaque {}

typedef _AbiVersionNative = Uint32 Function();
typedef _AbiVersionDart = int Function();
typedef _StandaloneOutputNative =
    Int32 Function(Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _StandaloneOutputDart =
    int Function(Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _VaultOpenNative =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<GetforVault>>,
    );
typedef _VaultOpenDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<GetforVault>>,
    );
typedef _VaultLockNative = Int32 Function(Pointer<GetforVault>);
typedef _VaultLockDart = int Function(Pointer<GetforVault>);
typedef _VaultChangePasswordNative =
    Int32 Function(
      Pointer<GetforVault>,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
    );
typedef _VaultChangePasswordDart =
    int Function(
      Pointer<GetforVault>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
    );
typedef _RecordListNative =
    Int32 Function(
      Pointer<GetforVault>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _RecordListDart =
    int Function(Pointer<GetforVault>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _RecordGetNative =
    Int32 Function(
      Pointer<GetforVault>,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _RecordGetDart =
    int Function(
      Pointer<GetforVault>,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _SyncTransferNative =
    Int32 Function(
      Pointer<GetforVault>,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _SyncTransferDart =
    int Function(
      Pointer<GetforVault>,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _PairingAcceptNative =
    Int32 Function(
      Pointer<GetforVault>,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
    );
typedef _PairingAcceptDart =
    int Function(
      Pointer<GetforVault>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
    );
typedef _RecordPutNative =
    Int32 Function(Pointer<GetforVault>, Pointer<Uint8>, Size);
typedef _RecordPutDart =
    int Function(Pointer<GetforVault>, Pointer<Uint8>, int);
typedef _BytesFreeNative = Int32 Function(Pointer<Uint8>, Size);
typedef _BytesFreeDart = int Function(Pointer<Uint8>, int);

final DynamicLibrary _core = _openCore();

final _AbiVersionDart _getforCoreAbiVersion = _core
    .lookupFunction<_AbiVersionNative, _AbiVersionDart>(
      'getfor_core_abi_version',
    );
final _StandaloneOutputDart _getforTlsIdentityCreate = _core
    .lookupFunction<_StandaloneOutputNative, _StandaloneOutputDart>(
      'getfor_tls_identity_create',
    );
final _VaultOpenDart _getforVaultCreate = _core
    .lookupFunction<_VaultOpenNative, _VaultOpenDart>('getfor_vault_create');
final _VaultOpenDart _getforVaultOpen = _core
    .lookupFunction<_VaultOpenNative, _VaultOpenDart>('getfor_vault_open');
final _VaultOpenDart _getforVaultOpenWithKey = _core
    .lookupFunction<_VaultOpenNative, _VaultOpenDart>(
      'getfor_vault_open_with_key',
    );
final _VaultLockDart _getforVaultLock = _core
    .lookupFunction<_VaultLockNative, _VaultLockDart>('getfor_vault_lock');
final _VaultChangePasswordDart _getforVaultChangePassword = _core
    .lookupFunction<_VaultChangePasswordNative, _VaultChangePasswordDart>(
      'getfor_vault_change_password',
    );
final _RecordListDart _getforRecordList = _core
    .lookupFunction<_RecordListNative, _RecordListDart>('getfor_record_list');
final _RecordGetDart _getforRecordGet = _core
    .lookupFunction<_RecordGetNative, _RecordGetDart>('getfor_record_get');
final _RecordPutDart _getforRecordPut = _core
    .lookupFunction<_RecordPutNative, _RecordPutDart>('getfor_record_put');
final _RecordPutDart _getforRecordDelete = _core
    .lookupFunction<_RecordPutNative, _RecordPutDart>('getfor_record_delete');
final _RecordListDart _getforSyncState = _core
    .lookupFunction<_RecordListNative, _RecordListDart>('getfor_sync_state');
final _RecordListDart _getforVaultQuickUnlockKey = _core
    .lookupFunction<_RecordListNative, _RecordListDart>(
      'getfor_vault_quick_unlock_key',
    );
final _RecordListDart _getforDeviceInfo = _core
    .lookupFunction<_RecordListNative, _RecordListDart>('getfor_device_info');
final _SyncTransferDart _getforSyncProof = _core
    .lookupFunction<_SyncTransferNative, _SyncTransferDart>(
      'getfor_sync_proof',
    );
final _SyncTransferDart _getforSyncExport = _core
    .lookupFunction<_SyncTransferNative, _SyncTransferDart>(
      'getfor_sync_export',
    );
final _SyncTransferDart _getforSyncImport = _core
    .lookupFunction<_SyncTransferNative, _SyncTransferDart>(
      'getfor_sync_import',
    );
final _RecordListDart _getforPairingOfferCreate = _core
    .lookupFunction<_RecordListNative, _RecordListDart>(
      'getfor_pairing_offer_create',
    );
final _PairingAcceptDart _getforPairingAccept = _core
    .lookupFunction<_PairingAcceptNative, _PairingAcceptDart>(
      'getfor_pairing_accept',
    );
final _BytesFreeDart _getforBytesFree = _core
    .lookupFunction<_BytesFreeNative, _BytesFreeDart>('getfor_bytes_free');

int getforCoreAbiVersion() => _getforCoreAbiVersion();

Map<String, dynamic> createTlsIdentity() {
  return (_readJson(_getforTlsIdentityCreate) as Map<dynamic, dynamic>)
      .cast<String, dynamic>();
}

final class VaultException implements Exception {
  const VaultException(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => message;
}

final class VaultItemSummary {
  const VaultItemSummary({
    required this.id,
    required this.title,
    required this.website,
    required this.username,
    required this.hasPassword,
    required this.hasTotp,
    this.hasPasskey = false,
    this.passkeyCount = 0,
  });

  factory VaultItemSummary.fromJson(Map<String, dynamic> json) {
    return VaultItemSummary(
      id: json['id'] as String,
      title: json['title'] as String,
      website: json['website'] as String,
      username: json['username'] as String,
      hasPassword: json['hasPassword'] as bool,
      hasTotp: json['hasTotp'] as bool,
      hasPasskey: json['hasPasskey'] as bool,
      passkeyCount: json['passkeyCount'] as int,
    );
  }

  final String id;
  final String title;
  final String website;
  final String username;
  final bool hasPassword;
  final bool hasTotp;
  final bool hasPasskey;
  final int passkeyCount;
}

final class VaultPasskey {
  const VaultPasskey({
    required this.credentialId,
    required this.relyingPartyId,
    required this.userHandle,
    required this.userName,
    required this.userDisplayName,
    required this.privateKeyPkcs8,
    this.backupEligible = true,
    this.backupState = false,
  });

  factory VaultPasskey.fromJson(Map<String, dynamic> json) => VaultPasskey(
    credentialId: json['credentialId'] as String,
    relyingPartyId: json['relyingPartyId'] as String,
    userHandle: json['userHandle'] as String,
    userName: json['userName'] as String,
    userDisplayName: json['userDisplayName'] as String? ?? '',
    privateKeyPkcs8: json['privateKeyPkcs8'] as String,
    backupEligible: json['backupEligible'] as bool? ?? true,
    backupState: json['backupState'] as bool? ?? false,
  );

  final String credentialId;
  final String relyingPartyId;
  final String userHandle;
  final String userName;
  final String userDisplayName;
  final String privateKeyPkcs8;
  final bool backupEligible;
  final bool backupState;

  Map<String, dynamic> toJson() => {
    'credentialId': credentialId,
    'relyingPartyId': relyingPartyId,
    'userHandle': userHandle,
    'userName': userName,
    'userDisplayName': userDisplayName,
    'privateKeyPkcs8': privateKeyPkcs8,
    'backupEligible': backupEligible,
    'backupState': backupState,
  };
}

final class VaultItem {
  const VaultItem({
    required this.id,
    required this.title,
    required this.website,
    required this.username,
    required this.password,
    required this.totpSecret,
    this.totpPeriod = 30,
    this.totpDigits = 6,
    this.totpAlgorithm = 'sha1',
    this.passkeys = const [],
  });

  factory VaultItem.fromJson(Map<String, dynamic> json) {
    return VaultItem(
      id: json['id'] as String,
      title: json['title'] as String,
      website: json['website'] as String,
      username: json['username'] as String,
      password: json['password'] as String,
      totpSecret: json['totpSecret'] as String,
      totpPeriod: json['totpPeriod'] as int,
      totpDigits: json['totpDigits'] as int,
      totpAlgorithm: json['totpAlgorithm'] as String,
      passkeys: (json['passkeys'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>()
          .map(VaultPasskey.fromJson)
          .toList(growable: false),
    );
  }

  final String id;
  final String title;
  final String website;
  final String username;
  final String password;
  final String totpSecret;
  final int totpPeriod;
  final int totpDigits;
  final String totpAlgorithm;
  final List<VaultPasskey> passkeys;

  bool get hasPassword => password.isNotEmpty;
  bool get hasTotp => totpSecret.isNotEmpty;
  bool get hasPasskey => passkeys.isNotEmpty;
}

final class VaultSession {
  VaultSession._(this._handle);

  Pointer<GetforVault>? _handle;

  static VaultSession create(String path, String password) {
    return _createOrOpen(path, password, create: true);
  }

  static VaultSession open(String path, String password) {
    return _createOrOpen(path, password, create: false);
  }

  static VaultSession openWithKey(String path, Uint8List key) {
    final nativePath = _NativeBytes.fromString(path);
    final nativeKey = _NativeBytes.fromBytes(key);
    final output = calloc<Pointer<GetforVault>>();
    try {
      _checkStatus(
        _getforVaultOpenWithKey(
          nativePath.pointer,
          nativePath.length,
          nativeKey.pointer,
          nativeKey.length,
          output,
        ),
      );
      return VaultSession._(output.value);
    } finally {
      nativePath.dispose();
      nativeKey.dispose(clear: true);
      calloc.free(output);
    }
  }

  static VaultSession _createOrOpen(
    String path,
    String password, {
    required bool create,
  }) {
    final nativePath = _NativeBytes.fromString(path);
    final nativePassword = _NativeBytes.fromString(password);
    final output = calloc<Pointer<GetforVault>>();
    try {
      final status = (create ? _getforVaultCreate : _getforVaultOpen)(
        nativePath.pointer,
        nativePath.length,
        nativePassword.pointer,
        nativePassword.length,
        output,
      );
      _checkStatus(status);
      return VaultSession._(output.value);
    } finally {
      nativePath.dispose();
      // Password copies crossing FFI are cleared immediately after the call.
      nativePassword.dispose(clear: true);
      calloc.free(output);
    }
  }

  List<VaultItemSummary> listItems() {
    final json = _readJson(
      (outData, outLength) =>
          _getforRecordList(_requireHandle(), outData, outLength),
    );
    return (json as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(VaultItemSummary.fromJson)
        .toList(growable: false);
  }

  VaultItem getItem(String id) {
    final nativeId = _NativeBytes.fromString(id);
    try {
      final json = _readJson(
        (outData, outLength) => _getforRecordGet(
          _requireHandle(),
          nativeId.pointer,
          nativeId.length,
          outData,
          outLength,
        ),
      );
      return VaultItem.fromJson((json as Map).cast<String, dynamic>());
    } finally {
      nativeId.dispose();
    }
  }

  void saveItem({
    String? id,
    required String title,
    required String website,
    required String username,
    required String password,
    required String totpSecret,
    int totpPeriod = 30,
    int totpDigits = 6,
    String totpAlgorithm = 'sha1',
    List<VaultPasskey> passkeys = const [],
  }) {
    final json = jsonEncode({
      if (id != null) 'id': id,
      'title': title,
      'website': website,
      'username': username,
      'password': password,
      'totpSecret': totpSecret,
      'totpPeriod': totpPeriod,
      'totpDigits': totpDigits,
      'totpAlgorithm': totpAlgorithm,
      'passkeys': passkeys.map((passkey) => passkey.toJson()).toList(),
    });
    final nativeJson = _NativeBytes.fromString(json);
    try {
      _checkStatus(
        _getforRecordPut(
          _requireHandle(),
          nativeJson.pointer,
          nativeJson.length,
        ),
      );
    } finally {
      nativeJson.dispose(clear: true);
    }
  }

  void deleteItem(String id) {
    final nativeId = _NativeBytes.fromString(id);
    try {
      _checkStatus(
        _getforRecordDelete(
          _requireHandle(),
          nativeId.pointer,
          nativeId.length,
        ),
      );
    } finally {
      nativeId.dispose();
    }
  }

  void changePassword(String currentPassword, String newPassword) {
    final current = _NativeBytes.fromString(currentPassword);
    final replacement = _NativeBytes.fromString(newPassword);
    try {
      _checkStatus(
        _getforVaultChangePassword(
          _requireHandle(),
          current.pointer,
          current.length,
          replacement.pointer,
          replacement.length,
        ),
      );
    } finally {
      current.dispose(clear: true);
      replacement.dispose(clear: true);
    }
  }

  Uint8List quickUnlockKey() => _readBytes(
    (outData, outLength) =>
        _getforVaultQuickUnlockKey(_requireHandle(), outData, outLength),
  );

  Map<String, dynamic> syncState() {
    return (_readJson(
              (outData, outLength) =>
                  _getforSyncState(_requireHandle(), outData, outLength),
            )
            as Map<dynamic, dynamic>)
        .cast<String, dynamic>();
  }

  String get deviceId {
    final value =
        _readJson(
              (outData, outLength) =>
                  _getforDeviceInfo(_requireHandle(), outData, outLength),
            )
            as Map<String, dynamic>;
    return value['deviceId'] as String;
  }

  Uint8List syncProof(Uint8List challenge) {
    final input = _NativeBytes.fromBytes(challenge);
    try {
      return _readBytes(
        (outData, outLength) => _getforSyncProof(
          _requireHandle(),
          input.pointer,
          input.length,
          outData,
          outLength,
        ),
      );
    } finally {
      input.dispose(clear: true);
    }
  }

  Uint8List exportSyncBundle(Map<String, dynamic> peerState) {
    final input = _NativeBytes.fromString(jsonEncode(peerState));
    try {
      return _readBytes(
        (outData, outLength) => _getforSyncExport(
          _requireHandle(),
          input.pointer,
          input.length,
          outData,
          outLength,
        ),
      );
    } finally {
      input.dispose();
    }
  }

  int importSyncBundle(Uint8List bundle) {
    final input = _NativeBytes.fromBytes(bundle);
    try {
      final response =
          _readJson(
                (outData, outLength) => _getforSyncImport(
                  _requireHandle(),
                  input.pointer,
                  input.length,
                  outData,
                  outLength,
                ),
              )
              as Map<String, dynamic>;
      return response['imported'] as int;
    } finally {
      input.dispose(clear: true);
    }
  }

  Map<String, dynamic> createPairingOffer() {
    return (_readJson(
              (outData, outLength) => _getforPairingOfferCreate(
                _requireHandle(),
                outData,
                outLength,
              ),
            )
            as Map<dynamic, dynamic>)
        .cast<String, dynamic>();
  }

  void acceptPairing(Map<String, dynamic> offer, String currentPassword) {
    final encodedOffer = _NativeBytes.fromString(jsonEncode(offer));
    final password = _NativeBytes.fromString(currentPassword);
    try {
      _checkStatus(
        _getforPairingAccept(
          _requireHandle(),
          encodedOffer.pointer,
          encodedOffer.length,
          password.pointer,
          password.length,
        ),
      );
    } finally {
      encodedOffer.dispose(clear: true);
      password.dispose(clear: true);
    }
  }

  void lock() {
    final handle = _requireHandle();
    _checkStatus(_getforVaultLock(handle));
    _handle = null;
  }

  Pointer<GetforVault> _requireHandle() {
    final handle = _handle;
    if (handle == null) {
      throw const VaultException(1, '保险库已经锁定');
    }
    return handle;
  }
}

dynamic _readJson(
  int Function(Pointer<Pointer<Uint8>>, Pointer<Size>) operation,
) {
  final output = calloc<Pointer<Uint8>>();
  final outputLength = calloc<Size>();
  Uint8List? copied;
  try {
    _checkStatus(operation(output, outputLength));
    copied = Uint8List.fromList(output.value.asTypedList(outputLength.value));
    return jsonDecode(utf8.decode(copied));
  } finally {
    if (output.value != nullptr && outputLength.value > 0) {
      _getforBytesFree(output.value, outputLength.value);
    }
    copied?.fillRange(0, copied.length, 0);
    calloc.free(output);
    calloc.free(outputLength);
  }
}

Uint8List _readBytes(
  int Function(Pointer<Pointer<Uint8>>, Pointer<Size>) operation,
) {
  final output = calloc<Pointer<Uint8>>();
  final outputLength = calloc<Size>();
  try {
    _checkStatus(operation(output, outputLength));
    return Uint8List.fromList(output.value.asTypedList(outputLength.value));
  } finally {
    if (output.value != nullptr && outputLength.value > 0) {
      _getforBytesFree(output.value, outputLength.value);
    }
    calloc.free(output);
    calloc.free(outputLength);
  }
}

void _checkStatus(int status) {
  if (status == 0) {
    return;
  }
  const messages = {
    1: '输入内容无效',
    2: '保险库已经存在',
    3: '主密码错误或保险库已损坏',
    4: '无法读写保险库',
    5: '保险库发生内部错误',
    6: '密码条目不存在',
  };
  throw VaultException(status, messages[status] ?? '未知保险库错误');
}

final class _NativeBytes {
  _NativeBytes._(this.pointer, this.length);

  factory _NativeBytes.fromString(String value) {
    final bytes = utf8.encode(value);
    final pointer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    if (bytes.isNotEmpty) {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
    }
    return _NativeBytes._(pointer, bytes.length);
  }

  factory _NativeBytes.fromBytes(Uint8List bytes) {
    final pointer = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    if (bytes.isNotEmpty) pointer.asTypedList(bytes.length).setAll(0, bytes);
    return _NativeBytes._(pointer, bytes.length);
  }

  final Pointer<Uint8> pointer;
  final int length;

  void dispose({bool clear = false}) {
    if (clear && length > 0) {
      pointer.asTypedList(length).fillRange(0, length, 0);
    }
    calloc.free(pointer);
  }
}

DynamicLibrary _openCore() {
  // macOS force-loads a static library; Android packages a dynamic library.
  if (Platform.isMacOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libgetfor_core.so');
  }
  throw UnsupportedError('getfor_core is not built for this platform');
}
