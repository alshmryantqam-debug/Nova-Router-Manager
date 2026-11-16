import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/features/pppoe/pppoe_pro_service.dart';

PppoeSubscriber _subscriber(String comment) => PppoeSubscriber(
      id: '*1',
      name: 'test-user',
      profile: 'default',
      disabled: false,
      comment: comment,
      callerId: '',
      online: false,
      address: '',
      activeId: '',
      uptime: '',
      sessionRxBytes: 0,
      sessionTxBytes: 0,
      rxMbps: 0,
      txMbps: 0,
      lastLoggedOut: '',
      lastDisconnectReason: '',
      queueId: '',
      queueName: '',
      maxLimit: '',
    );

void main() {
  group('PPPoE expiry marker', () {
    test('parses expiry marker after an existing comment', () {
      final subscriber = _subscriber('residential plan EXP:2099-12-31');
      expect(subscriber.expiry, DateTime(2099, 12, 31));
      expect(subscriber.expired, isFalse);
    });

    test('returns null when no expiry marker exists', () {
      expect(_subscriber('residential plan').expiry, isNull);
    });

    test('recognizes an expired date marker', () {
      final subscriber = _subscriber('EXP:2000-01-01');
      expect(subscriber.expired, isTrue);
    });
  });
}
