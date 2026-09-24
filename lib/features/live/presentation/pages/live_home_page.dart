/// Pantalla principal (equivalente a `profile_page.dart` en el manual de
/// arquitectura): un `ConsumerWidget` que observa [liveControllerProvider] y
/// dispara acciones sobre su notifier. No conoce WebSockets, audio nativo ni
/// cámara: solo el [LiveUiState] expuesto por el controller.
///
/// Interfaz voz-first con solo dos acciones táctiles: tocar cualquier parte de la
/// pantalla para iniciar y un botón grande "Detener" abajo. Todo lo demás se hace
/// por voz.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/live_providers.dart';
import '../widgets/transcript_line.dart';

/// Alto del botón Detener: grande para encontrarlo sin buscar (≥ 72 dp).
const double stopButtonHeight = 80;

/// Rojo del botón Detener con texto blanco: contraste ~5,6:1 (WCAG AA).
const Color stopButtonColor = Color(0xFFC62828);

/// Lo que lee TalkBack sobre el botón.
const String stopButtonSemanticsLabel = 'Detener asistente';

class LiveHomePage extends ConsumerWidget {
  const LiveHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(liveControllerProvider);
    final controller = ref.read(liveControllerProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Toda el área superior es el gesto de inicio. Con TalkBack se anuncia
            // el estado y un doble toque hace lo mismo que un toque.
            Expanded(
              child: Semantics(
                container: true,
                liveRegion: true,
                label: state.statusLabel,
                onTap: controller.onTap,
                child: GestureDetector(
                  onTap: controller.onTap,
                  behavior: HitTestBehavior.opaque,
                  excludeFromSemantics: true,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ExcludeSemantics(
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
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (state.isLive)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SizedBox(
                  width: double.infinity,
                  height: stopButtonHeight,
                  child: FilledButton.icon(
                    onPressed: controller.disconnect,
                    style: FilledButton.styleFrom(
                      backgroundColor: stopButtonColor,
                      foregroundColor: Colors.white,
                      textStyle: theme.textTheme.headlineSmall,
                    ),
                    icon: const Icon(Icons.stop, size: 36),
                    label: const Text(
                      'Detener',
                      semanticsLabel: stopButtonSemanticsLabel,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
