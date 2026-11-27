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
  group('PIN credential persistence', () {
    test('restores the previous PIN pair when the hash write fails', () async {
      final values = <String, String>{
        'salt': 'previous-salt',
        'hash': 'previous-hash',
      };
      var failHashWrite = true;

      Future<String?> read(String key) async => values[key];
      Future<void> write(String key, String value) async {
        if (key == 'hash' && failHashWrite) {
          failHashWrite = false;
          throw StateError('simulated secure-storage write failure');
        }
        values[key] = value;
      }
      Future<void> delete(String key) async {
        values.remove(key);
      }

      await expectLater(
        PinCredentialPersistence.writePair(
          saltKey: 'salt',
          hashKey: 'hash',
          saltValue: 'new-salt',
          hashValue: 'new-hash',
          read: read,
          write: write,
          delete: delete,
        ),
        throwsA(isA<StateError>()),
      );

      expect(values, <String, String>{
        'salt': 'previous-salt',
        'hash': 'previous-hash',
      });
    });

    test('removes a partial new PIN pair when setup fails', () async {
      final values = <String, String>{};
      var failHashWrite = true;

      Future<String?> read(String key) async => values[key];
      Future<void> write(String key, String value) async {
        if (key == 'hash' && failHashWrite) {
          failHashWrite = false;
          throw StateError('simulated secure-storage write failure');
        }
        values[key] = value;
      }
      Future<void> delete(String key) async {
        values.remove(key);
      }

      await expectLater(
        PinCredentialPersistence.writePair(
          saltKey: 'salt',
          hashKey: 'hash',
          saltValue: 'new-salt',
          hashValue: 'new-hash',
          read: read,
          write: write,
          delete: delete,
        ),
        throwsA(isA<StateError>()),
      );

      expect(values, isEmpty);
    });

    test('writes both values when secure storage is available', () async {
      final values = <String, String>{};

      Future<String?> read(String key) async => values[key];
      Future<void> write(String key, String value) async {
        values[key] = value;
      }
      Future<void> delete(String key) async {
        values.remove(key);
      }

      await PinCredentialPersistence.writePair(
        saltKey: 'salt',
        hashKey: 'hash',
        saltValue: 'new-salt',
        hashValue: 'new-hash',
        read: read,
        write: write,
        delete: delete,
      );

      expect(values, <String, String>{
        'salt': 'new-salt',
        'hash': 'new-hash',
      });
    });
  });

}
