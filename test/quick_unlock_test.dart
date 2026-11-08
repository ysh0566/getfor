import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getfor/quick_unlock.dart';

void main() {
  test('loaded quick-unlock key can be cleared', () async {
    final key = await QuickUnlockClient(
      channel: const _UnmodifiableKeyChannel(),
    ).loadKey();
    expect(key, isNotNull);
    key!.fillRange(0, key.length, 0);
    expect(key, Uint8List.fromList([0, 0, 0]));
  });
}

final class _UnmodifiableKeyChannel extends MethodChannel {
  const _UnmodifiableKeyChannel() : super('test');

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async =>
      Uint8List.fromList([1, 2, 3]).asUnmodifiableView() as T;
}
