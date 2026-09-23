import 'package:app/features/live/data/repositories/live_settings_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<LiveSettingsRepositoryImpl> repo([
    Map<String, Object> values = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(values);
    return LiveSettingsRepositoryImpl(await SharedPreferences.getInstance());
  }

  test('valores por defecto sin ajustes guardados', () async {
    final r = await repo();
    expect(r.getAssistantName(), defaultAssistantName);
    expect(r.getUserName(), isEmpty);
    expect(r.getVoice(), isEmpty);
    expect(r.getVerbosity(), 'concise');
    expect(r.getDescribing(), isTrue);
    expect(r.getSystemCuesMuted(), isFalse);
  });

  test('persiste los ajustes entre instancias', () async {
    final r = await repo();
    await r.setAssistantName('Sol');
    await r.setUserName('Andrés');
    await r.setVoice('Kore');
    await r.setVerbosity('detailed');
    await r.setDescribing(false);

    final again = LiveSettingsRepositoryImpl(
      await SharedPreferences.getInstance(),
    );
    expect(again.getAssistantName(), 'Sol');
    expect(again.getUserName(), 'Andrés');
    expect(again.getVoice(), 'Kore');
    expect(again.getVerbosity(), 'detailed');
    expect(again.getDescribing(), isFalse);
  });

  test('ignora nombres vacíos y voces que no existen', () async {
    final r = await repo();
    await r.setAssistantName('   ');
    await r.setVoice('VozInventada');
    expect(r.getAssistantName(), defaultAssistantName);
    expect(r.getVoice(), isEmpty);
  });
}
