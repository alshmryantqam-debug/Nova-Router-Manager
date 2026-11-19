import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/features/settings/app_security_service.dart';

void main() {
  test('PIN attempts remain available before the fifth failure', () {
    for (var failures = 0; failures < 5; failures++) {
      expect(PinAttemptPolicy.lockoutForFailureCount(failures), isNull);
    }
  });

  test('PIN lockout increases after repeated failure groups', () {
    expect(
      PinAttemptPolicy.lockoutForFailureCount(5),
      const Duration(seconds: 30),
    );
    expect(
      PinAttemptPolicy.lockoutForFailureCount(9),
      const Duration(seconds: 30),
    );
    expect(
      PinAttemptPolicy.lockoutForFailureCount(10),
      const Duration(minutes: 2),
    );
    expect(
      PinAttemptPolicy.lockoutForFailureCount(14),
      const Duration(minutes: 2),
    );
    expect(
      PinAttemptPolicy.lockoutForFailureCount(15),
      const Duration(minutes: 5),
    );
    expect(
      PinAttemptPolicy.lockoutForFailureCount(100),
      const Duration(minutes: 5),
    );
  });
}
