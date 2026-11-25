import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/features/settings/app_security_service.dart';

void main() {
  test('PIN is disabled only when both secure-storage values are absent', () {
    expect(PinStorageState.isEnabled(null, null), isFalse);
  });

  test('accepts a complete PIN salt and hash pair', () {
    final salt = base64Encode(List<int>.filled(16, 0x2A));
    final hash = base64Encode(List<int>.filled(32, 0x5C));

    expect(PinStorageState.isEnabled(salt, hash), isTrue);
  });

  test('rejects partial or empty PIN state instead of unlocking the app', () {
    final salt = base64Encode(List<int>.filled(16, 0x2A));
    final hash = base64Encode(List<int>.filled(32, 0x5C));

    expect(() => PinStorageState.isEnabled(salt, null), throwsFormatException);
    expect(() => PinStorageState.isEnabled(null, hash), throwsFormatException);
    expect(() => PinStorageState.isEnabled('', ''), throwsFormatException);
  });

  test('rejects malformed base64 and unexpected stored lengths', () {
    final validSalt = base64Encode(List<int>.filled(16, 0x2A));
    final validHash = base64Encode(List<int>.filled(32, 0x5C));

    expect(
      () => PinStorageState.isEnabled('not-base64!', validHash),
      throwsFormatException,
    );
    expect(
      () => PinStorageState.isEnabled(
        base64Encode(List<int>.filled(15, 0x2A)),
        validHash,
      ),
      throwsFormatException,
    );
    expect(
      () => PinStorageState.isEnabled(
        validSalt,
        base64Encode(List<int>.filled(31, 0x5C)),
      ),
      throwsFormatException,
    );
  });
}
