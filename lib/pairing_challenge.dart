import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

final class PairingChallenge {
  PairingChallenge._({
    required this.requestId,
    required this.code,
    required this.expiresAt,
    required Map<String, dynamic> offer,
  }) : _offer = offer;

  factory PairingChallenge.create(
    Map<String, dynamic> offer, {
    Random? random,
    DateTime? now,
  }) {
    final source = random ?? Random.secure();
    final requestId = base64UrlEncode(
      Uint8List.fromList(List.generate(16, (_) => source.nextInt(256))),
    ).replaceAll('=', '');
    final code = List.generate(6, (_) => source.nextInt(10)).join();
    return PairingChallenge._(
      requestId: requestId,
      code: code,
      expiresAt: (now ?? DateTime.now()).add(const Duration(minutes: 2)),
      offer: Map<String, dynamic>.unmodifiable(offer),
    );
  }

  final String requestId;
  final String code;
  final DateTime expiresAt;
  final Map<String, dynamic> _offer;
  bool _consumed = false;

  bool get isExpired => !DateTime.now().isBefore(expiresAt);

  Map<String, dynamic>? consume(String candidate, {DateTime? now}) {
    if (_consumed || !(now ?? DateTime.now()).isBefore(expiresAt)) {
      _consumed = true;
      return null;
    }
    // A matching request gets exactly one attempt, including malformed input.
    _consumed = true;
    return _constantTimeCodeEquals(code, candidate) ? _offer : null;
  }

  void cancel() => _consumed = true;
}

bool _constantTimeCodeEquals(String expected, String candidate) {
  var mismatch = expected.length ^ candidate.length;
  for (var index = 0; index < expected.length; index++) {
    mismatch |=
        expected.codeUnitAt(index) ^
        (index < candidate.length ? candidate.codeUnitAt(index) : 0);
  }
  return mismatch == 0;
}
