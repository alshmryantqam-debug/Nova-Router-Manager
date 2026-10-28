import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nova_router_manager/core/network/routeros_compatibility.dart';

import 'package:nova_router_manager/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Nova root screen opens without throwing', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: NovaRouterManagerApp()));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Allow the router-list first frame and async persisted-router load to
    // settle. No real router credentials or live router are required.
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}


  test('RouterOS capability model distinguishes v6 and v7', () {
    const v6 = RouterOsCapabilities(
      version: '6.49.17',
      majorVersion: 6,
      rest: false,
      api: true,
      wireless: true,
      wifi: false,
      wireguard: false,
    );
    const v7 = RouterOsCapabilities(
      version: '7.24.5',
      majorVersion: 7,
      rest: true,
      api: true,
      wireless: false,
      wifi: true,
      wireguard: true,
    );

    expect(v6.supportsV7, isFalse);
    expect(v6.rest, isFalse);
    expect(v6.api, isTrue);
    expect(v7.supportsV7, isTrue);
    expect(v7.rest, isTrue);
    expect(v7.wifi, isTrue);
    expect(v7.wireguard, isTrue);
  });
