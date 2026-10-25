import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ignore: avoid_relative_lib_imports
import '../lib/main.dart';

void main() {
  testWidgets('HabitUp démarre sur l\'accueil', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const HabitUpApp());
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Shell), findsOneWidget);
  });
}