import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/debug/file_log.dart';
import 'features/live/presentation/pages/live_home_page.dart';
import 'features/live/presentation/providers/live_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kDebugMode) {
    // Evidencia de las pruebas en la calle, sin depender del PC.
    final dir = await getApplicationSupportDirectory();
    FileLog(File('${dir.path}/$fileLogName')).install();
  }
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
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
