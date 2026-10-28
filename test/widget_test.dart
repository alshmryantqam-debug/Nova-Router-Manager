import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_router_manager/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('NovaRouterManagerApp builds without an exception', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: NovaRouterManagerApp()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
