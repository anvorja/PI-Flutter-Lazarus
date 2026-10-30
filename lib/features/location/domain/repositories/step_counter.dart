/// Contrato del contador de pasos (HU-021). No sabe nada del plugin: eso vive
/// en `data`.
library;

abstract class StepCounter {
  /// Pasos contados desde [start]; 0 si el teléfono no tiene acelerómetro.
  int get steps;

  /// Empieza a contar desde cero.
  void start();

  void stop();
}
