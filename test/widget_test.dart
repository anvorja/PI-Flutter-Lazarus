// Smoke test del arranque: la pantalla inicial muestra "Toca para empezar".

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/main.dart';

void main() {
  testWidgets('muestra el estado inicial', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: const LazarusApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Toca para empezar'), findsOneWidget);
  });
}
