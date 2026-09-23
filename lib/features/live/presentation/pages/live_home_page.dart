/// Pantalla principal (equivalente a `profile_page.dart` en el manual de
/// arquitectura): un `ConsumerWidget` que observa [liveControllerProvider] y
/// dispara acciones sobre su notifier. No conoce WebSockets, audio nativo ni
/// cámara: solo el [LiveUiState] expuesto por el controller.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/live_providers.dart';
import '../widgets/transcript_line.dart';

class LiveHomePage extends ConsumerWidget {
  const LiveHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(liveControllerProvider);
    final controller = ref.read(liveControllerProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      body: GestureDetector(
        onTap: controller.onTap,
        behavior: HitTestBehavior.opaque,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Semantics(
                    liveRegion: true,
                    label: state.statusLabel,
                    child: Text(
                      state.statusLabel,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (state.userTranscript.isNotEmpty)
                    TranscriptLine(
                      icon: Icons.person,
                      text: state.userTranscript,
                    ),
                  if (state.assistantTranscript.isNotEmpty)
                    TranscriptLine(
                      icon: Icons.assistant,
                      text: state.assistantTranscript,
                    ),
                  const SizedBox(height: 32),
                  if (state.isLive)
                    FilledButton.icon(
                      onPressed: controller.disconnect,
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                      ),
                      icon: const Icon(Icons.stop),
                      label: const Text('Detener'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
