import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core_ffi.dart';
import 'pairing_challenge.dart';

final class LanPeer {
  const LanPeer({
    required this.id,
    required this.host,
    required this.port,
    required this.paired,
  });

  final String id;
  final String host;
  final int port;
  final bool paired;
}

final class LanSyncService {
  LanSyncService({
    required this.onPeersChanged,
    required this.onVaultChanged,
    required this.onPairingCode,
  });

  static const _channel = MethodChannel('com.ysh0566.getfor/lan_discovery');

  final ValueChanged<List<LanPeer>> onPeersChanged;
  final VoidCallback onVaultChanged;
  final ValueChanged<String> onPairingCode;
  final Map<String, LanPeer> _discovered = {};
  final Map<String, _PeerTrust> _trust = {};
  final Map<String, DateTime> _challenges = {};
  final Map<String, String> _requestedPairFingerprints = {};
  VaultSession? _session;
  HttpServer? _server;
  PairingChallenge? _pendingPairing;
  String? _pendingPairSecret;
  String? _identityFingerprint;
  bool _pairingAllowed = false;

  List<LanPeer> get peers => _discovered.values.toList(growable: false);
  String? get identityFingerprint => _identityFingerprint;
  bool get pairingAllowed => _pairingAllowed;

  Future<void> start(VaultSession session) async {
    await stop();
    _session = session;
    await _loadPeers();
    await _loadSettings();
    final identity = await _loadIdentity();
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChain(identity.certificatePath)
      ..usePrivateKey(identity.privateKeyPath);
    _identityFingerprint = identity.fingerprint;
    _server = await HttpServer.bindSecure(InternetAddress.anyIPv4, 0, context);
    _server!.listen(_handleRequest);
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'lanPeerFound') return;
      final value = (call.arguments as Map<Object?, Object?>);
      final id = value['id']! as String;
      _discovered[id] = LanPeer(
        id: id,
        host: value['host']! as String,
        port: value['port']! as int,
        paired: _trust[id]?.revoked == false,
      );
      onPeersChanged(peers);
    });
    await _refreshDiscovery();
  }

  Future<void> setPairingAllowed(bool allowed) async {
    _pairingAllowed = allowed;
    if (!allowed) {
      _pendingPairing?.cancel();
      _pendingPairing = null;
      _pendingPairSecret = null;
    }
    await _saveSettings();
    if (_server != null && _session != null) await _refreshDiscovery();
  }

  Future<String> requestPairing(LanPeer peer) async {
    final client = _clientFor(peer, allowUnpaired: true);
    try {
      final request = await client.postUrl(_uri(peer, '/pairing/request'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'deviceId': _session!.deviceId}));
      final response = await request.close();
      if (response.statusCode == HttpStatus.forbidden) {
        throw StateError('对方未允许配对');
      }
      if (response.statusCode == HttpStatus.conflict) {
        throw StateError('对方正在处理另一个配对请求');
      }
      if (response.statusCode != HttpStatus.ok) throw StateError('无法请求配对');
      final value =
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
      final requestId = value['requestId'] as String;
      final fingerprint = _lastServerFingerprint;
      if (fingerprint == null) throw StateError('无法验证对方证书');
      _requestedPairFingerprints[requestId] = fingerprint;
      return requestId;
    } finally {
      client.close(force: true);
    }
  }

  Future<int> confirmPairing(
    LanPeer peer,
    String requestId,
    String code,
    String masterPassword,
  ) async {
    final fingerprint = _requestedPairFingerprints.remove(requestId);
    if (fingerprint == null) throw StateError('配对请求已失效');
    final client = _clientFor(peer, expectedFingerprint: fingerprint);
    try {
      final request = await client.postUrl(_uri(peer, '/pairing/confirm'));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'requestId': requestId, 'code': code.trim()}));
      final response = await request.close();
      if (response.statusCode == HttpStatus.unauthorized) {
        throw StateError('验证码错误，已失效');
      }
      if (response.statusCode != HttpStatus.ok) throw StateError('配对请求已失效');
      final offer =
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
      _session!.acceptPairing(offer, masterPassword);
      _trust[peer.id] = _PeerTrust(
        secret: sha256
            .convert(utf8.encode(offer['token'] as String))
            .toString(),
        fingerprint: fingerprint,
        revoked: false,
      );
      await _savePeers();
      _discovered[peer.id] = LanPeer(
        id: peer.id,
        host: peer.host,
        port: peer.port,
        paired: true,
      );
      onPeersChanged(peers);
      return await sync(peer);
    } finally {
      client.close(force: true);
    }
  }

  Future<int> sync(LanPeer peer) async {
    final trust = _trust[peer.id];
    if (trust == null || trust.revoked) {
      throw StateError('设备尚未配对');
    }
    final client = _clientFor(peer);
    try {
      final challengeRequest = await client.getUrl(_uri(peer, '/challenge'));
      final challengeResponse = await challengeRequest.close();
      final challenge = await utf8.decoder.bind(challengeResponse).join();
      final proof = base64Encode(
        Hmac(
          sha256,
          _hexBytes(trust.secret),
        ).convert(base64Decode(challenge)).bytes,
      );

      final stateRequest = await client.getUrl(_uri(peer, '/state'));
      _authenticate(stateRequest, challenge, proof);
      final stateResponse = await stateRequest.close();
      if (stateResponse.statusCode != HttpStatus.ok) throw StateError('设备认证失败');
      if (trust.fingerprint.isEmpty && _lastServerFingerprint != null) {
        _trust[peer.id] = _PeerTrust(
          secret: trust.secret,
          fingerprint: _lastServerFingerprint!,
          revoked: false,
        );
        await _savePeers();
      }
      final peerState =
          jsonDecode(await utf8.decoder.bind(stateResponse).join())
              as Map<String, dynamic>;
      final outgoing = _session!.exportSyncBundle(peerState);

      final syncRequest = await client.postUrl(_uri(peer, '/sync'));
      _authenticate(syncRequest, challenge, proof);
      syncRequest.headers.contentType = ContentType.json;
      syncRequest.write(
        jsonEncode({
          'state': _session!.syncState(),
          'bundle': base64Encode(outgoing),
        }),
      );
      final syncResponse = await syncRequest.close();
      if (syncResponse.statusCode != HttpStatus.ok) throw StateError('同步失败');
      final response =
          jsonDecode(await utf8.decoder.bind(syncResponse).join())
              as Map<String, dynamic>;
      final imported = _session!.importSyncBundle(
        base64Decode(response['bundle'] as String),
      );
      if (imported > 0) onVaultChanged();
      return imported;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> revoke(String deviceId) async {
    final current = _trust[deviceId];
    if (current != null) {
      _trust[deviceId] = _PeerTrust(
        secret: current.secret,
        fingerprint: current.fingerprint,
        revoked: true,
      );
    }
    final peer = _discovered[deviceId];
    if (peer != null) {
      _discovered[deviceId] = LanPeer(
        id: peer.id,
        host: peer.host,
        port: peer.port,
        paired: false,
      );
    }
    await _savePeers();
    onPeersChanged(peers);
  }

  Future<void> stop() async {
    _session = null;
    _pendingPairing?.cancel();
    _pendingPairing = null;
    _pendingPairSecret = null;
    _requestedPairFingerprints.clear();
    _challenges.clear();
    await _channel.invokeMethod<void>('stop').catchError((_) {});
    await _server?.close(force: true);
    _server = null;
    _channel.setMethodCallHandler(null);
  }

  String? _lastServerFingerprint;

  HttpClient _clientFor(
    LanPeer peer, {
    bool allowUnpaired = false,
    String? expectedFingerprint,
  }) {
    _lastServerFingerprint = null;
    final expected = _trust[peer.id]?.fingerprint;
    return HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..badCertificateCallback = (certificate, host, port) {
        final fingerprint = sha256.convert(certificate.der).toString();
        _lastServerFingerprint = fingerprint;
        return allowUnpaired ||
            fingerprint == expectedFingerprint ||
            (expectedFingerprint == null &&
                (expected == null ||
                    expected.isEmpty ||
                    fingerprint == expected));
      };
  }

  Uri _uri(LanPeer peer, String path) => Uri(
    scheme: 'https',
    host: peer.host.replaceFirst(RegExp(r'\.$'), ''),
    port: peer.port,
    path: path,
  );

  void _authenticate(
    HttpClientRequest request,
    String challenge,
    String proof,
  ) {
    request.headers
      ..set('x-getfor-device', _session!.deviceId)
      ..set('x-getfor-challenge', challenge)
      ..set('x-getfor-proof', proof);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final session = _session;
    if (session == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    try {
      if (request.method == 'POST' && request.uri.path == '/pairing/request') {
        await _handlePairingRequest(request, session);
      } else if (request.method == 'POST' &&
          request.uri.path == '/pairing/confirm') {
        await _handlePairingConfirmation(request);
      } else if (request.method == 'GET' && request.uri.path == '/challenge') {
        final random = Random.secure();
        final bytes = Uint8List.fromList(
          List.generate(24, (_) => random.nextInt(256)),
        );
        final challenge = base64Encode(bytes);
        _challenges[challenge] = DateTime.now().add(const Duration(minutes: 1));
        request.response.write(challenge);
      } else if (!_validProof(request, session)) {
        request.response.statusCode = HttpStatus.unauthorized;
      } else if (request.method == 'GET' && request.uri.path == '/state') {
        request.response.write(jsonEncode(session.syncState()));
      } else if (request.method == 'POST' && request.uri.path == '/sync') {
        final body = await utf8.decoder.bind(request).join();
        if (body.length > 6 * 1024 * 1024) {
          throw const FormatException('同步数据过大');
        }
        final value = jsonDecode(body) as Map<String, dynamic>;
        final imported = session.importSyncBundle(
          base64Decode(value['bundle'] as String),
        );
        final outgoing = session.exportSyncBundle(
          value['state'] as Map<String, dynamic>,
        );
        if (imported > 0) onVaultChanged();
        request.response.write(jsonEncode({'bundle': base64Encode(outgoing)}));
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    }
    await request.response.close();
  }

  Future<void> _handlePairingRequest(
    HttpRequest request,
    VaultSession session,
  ) async {
    if (!_pairingAllowed) {
      request.response.statusCode = HttpStatus.forbidden;
      return;
    }
    final current = _pendingPairing;
    if (current != null && !current.isExpired) {
      request.response.statusCode = HttpStatus.conflict;
      return;
    }
    final body = await utf8.decoder.bind(request).join();
    if (body.length > 1024) throw const FormatException('配对请求过大');
    final value = jsonDecode(body) as Map<String, dynamic>;
    final deviceId = value['deviceId'] as String?;
    if (deviceId == null ||
        deviceId == session.deviceId ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(deviceId)) {
      throw const FormatException('无效设备');
    }

    final offer = session.createPairingOffer();
    final challenge = PairingChallenge.create(offer);
    _pendingPairing = challenge;
    _pendingPairSecret = sha256
        .convert(utf8.encode(offer['token'] as String))
        .toString();
    onPairingCode(challenge.code);
    request.response.write(jsonEncode({'requestId': challenge.requestId}));
  }

  Future<void> _handlePairingConfirmation(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    if (body.length > 1024) throw const FormatException('配对确认过大');
    final value = jsonDecode(body) as Map<String, dynamic>;
    final requestId = value['requestId'] as String?;
    final code = value['code'] as String?;
    final pending = _pendingPairing;
    if (pending == null || requestId != pending.requestId || code == null) {
      request.response.statusCode = HttpStatus.notFound;
      return;
    }

    // Clear before comparing so every matching request ID gets exactly one attempt.
    _pendingPairing = null;
    final offer = pending.consume(code);
    if (offer == null) {
      _pendingPairSecret = null;
      request.response.statusCode = HttpStatus.unauthorized;
      return;
    }
    request.response.write(jsonEncode(offer));
  }

  Future<void> _refreshDiscovery() => _channel.invokeMethod<void>('start', {
    'port': _server!.port,
    'deviceId': _session!.deviceId,
    'advertise': _pairingAllowed,
  });

  bool _validProof(HttpRequest request, VaultSession session) {
    final challenge = request.headers.value('x-getfor-challenge');
    final proof = request.headers.value('x-getfor-proof');
    final expires = challenge == null ? null : _challenges[challenge];
    if (challenge == null ||
        proof == null ||
        expires == null ||
        expires.isBefore(DateTime.now())) {
      return false;
    }
    final deviceId = request.headers.value('x-getfor-device');
    if (deviceId == null) return false;
    final known = _trust[deviceId];
    if (known?.revoked == true) return false;
    final secret = known?.secret ?? _pendingPairSecret;
    if (secret == null) return false;
    final expected = Hmac(
      sha256,
      _hexBytes(secret),
    ).convert(base64Decode(challenge)).bytes;
    final actual = base64Decode(proof);
    var mismatch = expected.length ^ actual.length;
    for (var i = 0; i < min(expected.length, actual.length); i++) {
      mismatch |= expected[i] ^ actual[i];
    }
    if (mismatch != 0) return false;
    if (known == null) {
      _trust[deviceId] = _PeerTrust(
        secret: secret,
        fingerprint: '',
        revoked: false,
      );
      _pendingPairSecret = null;
      unawaited(_savePeers());
      final peer = _discovered[deviceId];
      if (peer != null) {
        _discovered[deviceId] = LanPeer(
          id: peer.id,
          host: peer.host,
          port: peer.port,
          paired: true,
        );
        onPeersChanged(peers);
      }
    }
    return true;
  }

  Future<({String certificatePath, String privateKeyPath, String fingerprint})>
  _loadIdentity() async {
    final directory = await getApplicationSupportDirectory();
    final certificate = File(
      '${directory.path}${Platform.pathSeparator}lan-cert.pem',
    );
    final privateKey = File(
      '${directory.path}${Platform.pathSeparator}lan-key.pem',
    );
    if (!await certificate.exists() || !await privateKey.exists()) {
      final identity = createTlsIdentity();
      await certificate.writeAsString(
        identity['certificatePem'] as String,
        flush: true,
      );
      await privateKey.writeAsString(
        identity['privateKeyPem'] as String,
        flush: true,
      );
      if (Platform.isMacOS) {
        await Process.run('chmod', ['600', privateKey.path]);
      }
    }
    final pem = await certificate.readAsString();
    final der = base64Decode(
      pem
          .split('\n')
          .where((line) => !line.startsWith('---') && line.isNotEmpty)
          .join(),
    );
    return (
      certificatePath: certificate.path,
      privateKeyPath: privateKey.path,
      fingerprint: sha256.convert(der).toString(),
    );
  }

  Future<File> _peersFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}lan-peers.json');
  }

  Future<File> _settingsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}lan-settings.json');
  }

  Future<void> _loadSettings() async {
    final file = await _settingsFile();
    if (!await file.exists()) return;
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _pairingAllowed = value['pairingAllowed'] == true;
  }

  Future<void> _saveSettings() async {
    final file = await _settingsFile();
    await file.writeAsString(
      jsonEncode({'pairingAllowed': _pairingAllowed}),
      flush: true,
    );
  }

  Future<void> _loadPeers() async {
    final file = await _peersFile();
    if (!await file.exists()) return;
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    _trust
      ..clear()
      ..addEntries(
        value.entries.map(
          (entry) => MapEntry(
            entry.key,
            _PeerTrust.fromJson(entry.value as Map<String, dynamic>),
          ),
        ),
      );
  }

  Future<void> _savePeers() async {
    final file = await _peersFile();
    await file.writeAsString(
      jsonEncode(_trust.map((key, value) => MapEntry(key, value.toJson()))),
      flush: true,
    );
    if (Platform.isMacOS) await Process.run('chmod', ['600', file.path]);
  }
}

final class _PeerTrust {
  const _PeerTrust({
    required this.secret,
    required this.fingerprint,
    required this.revoked,
  });

  factory _PeerTrust.fromJson(Map<String, dynamic> value) => _PeerTrust(
    secret: value['secret'] as String,
    fingerprint: value['fingerprint'] as String,
    revoked: value['revoked'] as bool,
  );

  final String secret;
  final String fingerprint;
  final bool revoked;

  Map<String, dynamic> toJson() => {
    'secret': secret,
    'fingerprint': fingerprint,
    'revoked': revoked,
  };
}

List<int> _hexBytes(String value) {
  if (value.length.isOdd) throw const FormatException('无效设备密钥');
  return [
    for (var index = 0; index < value.length; index += 2)
      int.parse(value.substring(index, index + 2), radix: 16),
  ];
}
