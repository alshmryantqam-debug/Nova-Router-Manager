import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/features/dhcp_binding/ip_address_validator.dart';

void main() {
  group('isValidIpAddressOrCidr', () {
    test('accepts valid IPv4 and IPv6 addresses with optional prefixes', () {
      expect(isValidIpAddressOrCidr('192.168.10.25'), isTrue);
      expect(isValidIpAddressOrCidr('192.168.10.0/24'), isTrue);
      expect(isValidIpAddressOrCidr('2001:db8::1'), isTrue);
      expect(isValidIpAddressOrCidr('2001:db8::/64'), isTrue);
      expect(isValidIpAddressOrCidr('::1/128'), isTrue);
      expect(isValidIpAddressOrCidr('0.0.0.0/0'), isTrue);
    });

    test('rejects malformed addresses and out-of-range prefixes', () {
      expect(isValidIpAddressOrCidr(''), isFalse);
      expect(isValidIpAddressOrCidr('router.local'), isFalse);
      expect(isValidIpAddressOrCidr('256.1.1.1'), isFalse);
      expect(isValidIpAddressOrCidr('192.168.1.1/33'), isFalse);
      expect(isValidIpAddressOrCidr('2001:db8::1/129'), isFalse);
      expect(isValidIpAddressOrCidr('192.168.1.1/-1'), isFalse);
      expect(isValidIpAddressOrCidr('192.168.1.1/24/8'), isFalse);
      expect(isValidIpAddressOrCidr('2001:db8:::1'), isFalse);
    });
  });
}
