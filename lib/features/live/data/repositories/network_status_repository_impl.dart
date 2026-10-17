/// [NetworkStatusRepository] con `connectivity_plus` (solo el permiso normal
/// ACCESS_NETWORK_STATE).
library;

import 'package:connectivity_plus/connectivity_plus.dart';

import '../../domain/repositories/network_status_repository.dart';

class NetworkStatusRepositoryImpl implements NetworkStatusRepository {
  final Connectivity _connectivity = Connectivity();

  static bool _hasData(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  @override
  Future<bool> isOnline() async {
    try {
      return _hasData(await _connectivity.checkConnectivity());
    } catch (_) {
      return true; // sin información: se intenta conectar como siempre
    }
  }

  @override
  Stream<bool> onlineChanges() =>
      _connectivity.onConnectivityChanged.map(_hasData).distinct();
}
