import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/core/network/router_error.dart';
import 'package:nova_router_manager/core/network/router_write_verifier.dart';
import 'package:nova_router_manager/core/network/routeros_client.dart';

void main() {
  group('runVerified', () {
    test('confirms matching read-back and normalizes RouterOS booleans', () async {
      final result = await runVerified(operation: VerifiedOperation.add, write: () async => {'ret': '*1'}, readBack: () async => {'name': 'voucher', 'disabled': 'yes'}, expected: const {'name': 'voucher', 'disabled': 'true'});
      expect(result.state, VerifiedWriteState.confirmed);
    });
    test('fails when read-back differs', () async {
      final result = await runVerified(operation: VerifiedOperation.set, write: () async => null, readBack: () async => {'profile': 'old'}, expected: const {'profile': 'fast'}, previous: const {'profile': 'old'});
      expect(result.state, VerifiedWriteState.failed);
    });
    test('timeout then applied is confirmed without replay', () async {
      var writes = 0; var applied = false;
      final result = await runVerified(operation: VerifiedOperation.add, write: () async { writes++; applied = true; throw TimeoutException('response lost'); }, readBack: () async => applied ? {'name': 'voucher'} : null, expected: const {'name': 'voucher'});
      expect(result.state, VerifiedWriteState.confirmed); expect(writes, 1);
    });
    test('timeout then not applied stays unconfirmed and is not replayed', () async {
      var writes = 0;
      final result = await runVerified(operation: VerifiedOperation.add, write: () async { writes++; throw TimeoutException('response lost'); }, readBack: () async => null, expected: const {'name': 'voucher'});
      expect(result.state, VerifiedWriteState.sentUnconfirmed); expect(writes, 1);
    });
    test('maps 401 to permission error', () {
      final error = RouterError.from(const RouterOsException('HTTP 401 Unauthorized'));
      expect(error.kind, RouterErrorKind.permission); expect(error.message, contains('صلاحيات'));
    });
    test('preserves 404/router error text', () {
      final error = RouterError.from(const RouterOsException('HTTP 404: no such item'));
      expect(error.kind, RouterErrorKind.routerRejected); expect(error.originalText, contains('no such item'));
    });
    test('maps untrusted TLS certificate', () {
      final error = RouterError.from(const RouterOsException('bad certificate'));
      expect(error.kind, RouterErrorKind.untrustedCertificate);
    });
  });
}
