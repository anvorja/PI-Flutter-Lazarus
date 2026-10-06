import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/debug/file_log.dart';
import 'core/telemetry/session_telemetry.dart';
import 'features/live/presentation/pages/live_home_page.dart';
import 'features/live/presentation/providers/live_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  if (kDebugMode) {
    // Evidencia de las pruebas en la calle, sin depender del PC.
    FileLog(File('${dir.path}/$fileLogName')).install();
  }
  // Telemetría sin contenido de la persona: también en distribución (HU-015).
  final telemetry = SessionTelemetry(
    fileTelemetrySink(File('${dir.path}/$telemetryFileName')),
  );
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        sessionTelemetryProvider.overrideWithValue(telemetry),
      ],
      child: const LazarusApp(),
    ),
  );
}

class LazarusApp extends StatelessWidget {
  const LazarusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lazarus',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const LiveHomePage(),
    );
  }
}
