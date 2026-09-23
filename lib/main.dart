import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/live/presentation/pages/live_home_page.dart';
import 'features/live/presentation/providers/live_providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
