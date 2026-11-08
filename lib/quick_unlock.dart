import 'package:flutter/services.dart';

final class QuickUnlockClient {
  QuickUnlockClient({
    MethodChannel channel = const MethodChannel(
      'com.ysh0566.getfor/quick_unlock',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<bool> hasKey() async =>
      await _channel.invokeMethod<bool>('hasKey') ?? false;

  Future<void> saveKey(Uint8List key) =>
      _channel.invokeMethod<void>('saveKey', key);

  Future<Uint8List?> loadKey() async {
    final key = await _channel.invokeMethod<Uint8List>('loadKey');
    // Platform channels may return an unmodifiable view; callers must be able to clear secrets.
    return key == null ? null : Uint8List.fromList(key);
  }
}
