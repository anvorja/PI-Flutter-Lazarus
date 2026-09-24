import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:app/features/live/presentation/pages/live_home_page.dart';
import 'package:app/features/live/presentation/providers/live_providers.dart';
import 'package:app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/fakes.dart';

/// HU-008: iniciar tocando cualquier parte y detener con un botón grande.
void main() {
  late FakeLiveSessionRepository session;
  late FakeMediaRepository media;
  late List<String> announcements;

  Future<void> pumpApp(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    session = FakeLiveSessionRepository();
    media = FakeMediaRepository();
    announcements = [];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          liveSessionRepositoryProvider.overrideWithValue(session),
          mediaRepositoryProvider.overrideWithValue(media),
          announcerProvider.overrideWithValue((m, _) => announcements.add(m)),
        ],
        child: const LazarusApp(),
      ),
    );
    await tester.pump();
  }

  Future<void> startSession(WidgetTester tester) async {
    await tester.tapAt(const Offset(40, 120)); // una esquina cualquiera
    await tester.pump();
    session.emitSetupComplete();
    await tester.pump();
  }

  final stopButton = find.byType(FilledButton);

  testWidgets('sin sesión: tocar cualquier parte inicia y no hay menús', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(stopButton, findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);

    await tester.tapAt(const Offset(40, 120));
    await tester.pump();
    expect(session.connectCalls, 1);
  });

  testWidgets('Detener: abajo, alto ≥ 72 dp, rojo y con contraste AA', (
    tester,
  ) async {
    await pumpApp(tester);
    await startSession(tester);

    expect(stopButton, findsOneWidget);
    final rect = tester.getRect(stopButton);
    final screen = tester.getSize(find.byType(Scaffold));
    expect(rect.height, greaterThanOrEqualTo(72));
    expect(rect.bottom, greaterThan(screen.height - 40)); // pegado abajo
    expect(rect.width, greaterThan(screen.width * 0.8));

    final ratio =
        (Colors.white.computeLuminance() + 0.05) /
        (stopButtonColor.computeLuminance() + 0.05);
    expect(ratio, greaterThanOrEqualTo(4.5));
  });

  testWidgets('Detener: cierra la sesión, libera y avisa', (tester) async {
    await pumpApp(tester);
    await startSession(tester);
    expect(media.micStarted, isTrue);
    expect(media.cameraStarted, isTrue);

    await tester.tap(stopButton);
    await tester.pump();

    expect(session.connected, isFalse);
    expect(media.micStarted, isFalse);
    expect(media.cameraStarted, isFalse);
    expect(announcements, [noticeText(LiveNotice.stopped, 'es')]);
    expect(stopButton, findsNothing);
  });

  testWidgets('TalkBack: el botón se anuncia como "Detener asistente"', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);
    await startSession(tester);

    expect(
      tester.getSemantics(stopButton),
      isSemantics(
        label: stopButtonSemanticsLabel,
        isButton: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('TalkBack: el área de inicio se anuncia y responde al toque', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpApp(tester);

    final area = find.bySemanticsLabel('Toca para empezar');
    expect(area, findsOneWidget);
    expect(
      tester.getSemantics(area),
      isSemantics(hasTapAction: true, isLiveRegion: true),
    );

    tester.semantics.tap(find.semantics.byLabel('Toca para empezar'));
    await tester.pump();
    expect(session.connectCalls, 1);
    semantics.dispose();
  });
}
