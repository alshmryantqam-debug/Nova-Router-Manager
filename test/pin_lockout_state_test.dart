import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/features/settings/app_security_service.dart';

void main() {
  group('PIN lockout state', () {
    final now = DateTime.utc(2026, 11, 28, 12);

    test('treats a missing lockout timestamp as no active lockout', () {
      final state = PinLockoutState.evaluate(null, now);

      expect(state.remaining, isNull);
      expect(state.needsRepair, isFalse);
    });

    test('preserves a valid active lockout duration', () {
      final stored = now.add(const Duration(seconds: 30)).millisecondsSinceEpoch;
      final state = PinLockoutState.evaluate(stored.toString(), now);

      expect(state.remaining, const Duration(seconds: 30));
      expect(state.needsRepair, isFalse);
    });

    test('clears an expired lockout timestamp', () {
      final stored = now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch;
      final state = PinLockoutState.evaluate(stored.toString(), now);

      expect(state.remaining, isNull);
      expect(state.needsRepair, isFalse);
    });

    test('repairs malformed timestamps with the maximum lockout', () {
      final state = PinLockoutState.evaluate('not-a-timestamp', now);

      expect(state.remaining, PinLockoutState.recoveryDuration);
      expect(state.needsRepair, isTrue);
    });

    test('repairs timestamps outside the supported lockout window', () {
      final stored = now.add(const Duration(hours: 2)).millisecondsSinceEpoch;
      final state = PinLockoutState.evaluate(stored.toString(), now);

      expect(state.remaining, PinLockoutState.recoveryDuration);
      expect(state.needsRepair, isTrue);
    });
  });

  group('PIN failure counter recovery', () {
    test('reads valid counters and treats missing storage as zero', () {
      expect(PinLockoutState.failureCount(null), 0);
      expect(PinLockoutState.failureCount('7'), 7);
    });

    test('recovers corrupt, negative, and oversized counters at the maximum', () {
      expect(PinLockoutState.failureCount('broken'), 15);
      expect(PinLockoutState.failureCount('-1'), 15);
      expect(PinLockoutState.failureCount('99'), 15);
    });
  });
}
