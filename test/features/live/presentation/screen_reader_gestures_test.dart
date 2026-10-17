/// HU-023: con TalkBack un toque solo enfoca, así que los avisos indican los
/// gestos de TalkBack (tocar dos veces, tocar dos veces y mantener).
library;

import 'package:app/features/live/presentation/controllers/live_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const languages = ['es', 'en', 'fr', 'pt', 'it'];

  /// Avisos que piden un gesto en la pantalla.
  const gestureNotices = [
    LiveNotice.connectionFailed,
    LiveNotice.sessionPaused,
    LiveNotice.permissionDenied,
    LiveNotice.permissionBlocked,
    LiveNotice.batteryExemption,
    LiveNotice.batteryExemptionXiaomi,
    LiveNotice.noData,
    LiveNotice.noDataReminder,
    LiveNotice.sosGestureConfirm,
  ];

  String adapted(LiveNotice n, String lang) =>
      withScreenReaderGestures(noticeText(n, lang), lang);

  test('en español: tocar dos veces y tocar dos veces y mantener', () {
    expect(
      adapted(LiveNotice.connectionFailed, 'es'),
      'No se pudo conectar con el servidor. Toca dos veces la pantalla para '
      'reintentar.',
    );
    expect(
      adapted(LiveNotice.noDataReminder, 'es'),
      'Sigo sin datos móviles. Para pedir ayuda, toca dos veces y mantén '
      'presionada la pantalla.',
    );
    expect(
      adapted(LiveNotice.sosGestureConfirm, 'es'),
      allOf(
        contains('vuelve a tocar dos veces y mantener presionada la pantalla'),
        contains('Para cancelar, toca dos veces.'),
      ),
    );
  });

  test('en inglés empieza la frase en mayúscula', () {
    expect(
      adapted(LiveNotice.connectionFailed, 'en'),
      'Could not connect to the server. Double-tap the screen to try again.',
    );
    expect(
      adapted(LiveNotice.batteryExemption, 'en'),
      contains('Then double-tap the screen to start.'),
    );
  });

  test('todos los avisos con gestos cambian, en los 5 idiomas', () {
    for (final lang in languages) {
      for (final n in gestureNotices) {
        expect(
          adapted(n, lang),
          isNot(noticeText(n, lang)),
          reason: '$n en $lang',
        );
      }
    }
  });

  test('los avisos sin gestos y el de silencio total no cambian', () {
    for (final lang in languages) {
      for (final n in [
        LiveNotice.stopped,
        LiveNotice.retrying,
        LiveNotice.sosCancelled,
        LiveNotice.muted,
      ]) {
        expect(adapted(n, lang), noticeText(n, lang), reason: '$n en $lang');
      }
    }
  });
}
