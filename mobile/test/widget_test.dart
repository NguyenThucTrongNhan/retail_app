import 'package:flutter_test/flutter_test.dart';
import 'package:retail_store/main.dart';

void main() {
  testWidgets('App smoke test — RetailApp renders without crashing',
      (WidgetTester tester) async {
    await tester.pumpWidget(const RetailApp());
    expect(find.byType(RetailApp), findsOneWidget);
  });
}
