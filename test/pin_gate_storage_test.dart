import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/features/settings/app_security_service.dart';

void main() {
  testWidgets('keeps the app locked when secure storage cannot be read', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppPinGate(
        pinEnabledReader: () async => throw StateError('secure storage unavailable'),
        child: const Text('Protected router dashboard'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('NOVA SECURITY LOCK'), findsOneWidget);
    expect(find.text('Protected router dashboard'), findsNothing);
    expect(find.textContaining('التطبيق مقفل احتياطياً'), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
  });

  testWidgets('retries the lock-state read without exposing content prematurely', (tester) async {
    var attempts = 0;
    Future<bool> readPinState() async {
      attempts++;
      if (attempts == 1) {
        throw StateError('temporary secure storage failure');
      }
      return true;
    }

    await tester.pumpWidget(MaterialApp(
      home: AppPinGate(
        pinEnabledReader: readPinState,
        child: const Text('Protected router dashboard'),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('NOVA SECURITY LOCK'), findsOneWidget);
    expect(find.textContaining('التطبيق مقفل احتياطياً'), findsNothing);
    expect(find.text('Protected router dashboard'), findsNothing);
  });
}
