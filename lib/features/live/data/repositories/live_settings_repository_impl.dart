/// Implementación concreta de [LiveSettingsRepository] sobre `SharedPreferences`.
///
/// Gracias al [LiveSettingsRepository] abstracto, `SharedPreferences` podría
/// sustituirse por otro almacenamiento (o por un fake en tests) sin tocar
/// el controller ni la UI.
library;

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/repositories/live_settings_repository.dart';

const String _nameKey = 'lazarus_assistant_name';
const String _userNameKey = 'lazarus_user_name';
const String _voiceKey = 'lazarus_voice';
const String _verbosityKey = 'lazarus_verbosity';
const String _describingKey = 'lazarus_describing';
const String _cuesMutedKey = 'lazarus_system_cues_muted';

const String defaultAssistantName = 'Aria';

/// Voces prebuilt de Gemini Live disponibles (deben coincidir con el enum del
/// backend en `live_service.set_voice`). Vacío = voz por defecto del backend.
const List<String> liveVoices = [
  'Charon',
  'Puck',
  'Kore',
  'Fenrir',
  'Aoede',
  'Leda',
  'Orus',
  'Zephyr',
];

class LiveSettingsRepositoryImpl implements LiveSettingsRepository {
  LiveSettingsRepositoryImpl(this._prefs);

  final SharedPreferences _prefs;

  @override
  String getAssistantName() {
    final v = _prefs.getString(_nameKey)?.trim();
    return (v == null || v.isEmpty) ? defaultAssistantName : v;
  }

  @override
  Future<void> setAssistantName(String name) async {
    final value = name.trim();
    if (value.isNotEmpty) await _prefs.setString(_nameKey, value);
  }

  @override
  String getUserName() => _prefs.getString(_userNameKey)?.trim() ?? '';

  @override
  Future<void> setUserName(String name) async {
    final value = name.trim();
    if (value.isNotEmpty) await _prefs.setString(_userNameKey, value);
  }

  @override
  String getVoice() {
    final stored = _prefs.getString(_voiceKey);
    return (stored != null && liveVoices.contains(stored)) ? stored : '';
  }

  @override
  Future<void> setVoice(String voice) async {
    if (liveVoices.contains(voice)) await _prefs.setString(_voiceKey, voice);
  }

  @override
  String getVerbosity() =>
      _prefs.getString(_verbosityKey) == 'detailed' ? 'detailed' : 'concise';

  @override
  Future<void> setVerbosity(String level) =>
      _prefs.setString(_verbosityKey, level);

  @override
  bool getDescribing() => _prefs.getString(_describingKey) != 'false';

  @override
  Future<void> setDescribing(bool enabled) =>
      _prefs.setString(_describingKey, enabled.toString());

  @override
  bool getSystemCuesMuted() => _prefs.getString(_cuesMutedKey) == 'true';

  @override
  Future<void> setSystemCuesMuted(bool muted) =>
      _prefs.setString(_cuesMutedKey, muted.toString());
}
