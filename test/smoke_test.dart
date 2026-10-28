import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
