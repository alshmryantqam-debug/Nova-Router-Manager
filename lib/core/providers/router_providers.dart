import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/routeros_client.dart';
import '../storage/router_storage_service.dart';

final routerStorageServiceProvider = Provider<RouterStorageService>(
  (ref) => RouterStorageService(),
);

/// Loads and maintains the persisted router list for the whole application.
final savedRoutersProvider =
    AsyncNotifierProvider<SavedRoutersController, List<SavedRouter>>(
  SavedRoutersController.new,
);

class SavedRoutersController extends AsyncNotifier<List<SavedRouter>> {
  late RouterStorageService _storage;

  @override
  Future<List<SavedRouter>> build() {
    _storage = ref.read(routerStorageServiceProvider);
    return _storage.loadRouters();
  }

  Future<void> saveRouter(SavedRouter router) async {
    final updated = await _storage.saveRouter(router);
    state = AsyncData<List<SavedRouter>>(updated);
  }

  Future<void> deleteRouter(String id) async {
    final updated = await _storage.deleteRouter(id);
    state = AsyncData<List<SavedRouter>>(updated);
    await ref.read(activeRouterClientProvider.notifier).disconnectIfRouter(id);
  }

  Future<void> reload() async {
    state = const AsyncLoading<List<SavedRouter>>();
    state = await AsyncValue.guard(_storage.loadRouters);
  }
}

/// Owns at most one authenticated RouterOS socket session at a time.
///
/// A replacement connection is tested before the active client is swapped, so
/// a failed connection attempt does not discard the previously active session.
final activeRouterClientProvider =
    StateNotifierProvider<ActiveRouterClientController, RouterOsClient?>(
  (ref) {
    final controller = ActiveRouterClientController();
    ref.onDispose(() {
      unawaited(controller.disconnect());
    });
    return controller;
  },
);

/// The saved profile associated with [activeRouterClientProvider].
final activeRouterDetailsProvider = Provider<SavedRouter?>((ref) {
  ref.watch(activeRouterClientProvider);
  return ref.read(activeRouterClientProvider.notifier).activeRouter;
});

class ActiveRouterClientController extends StateNotifier<RouterOsClient?> {
  ActiveRouterClientController() : super(null);

  SavedRouter? _activeRouter;

  SavedRouter? get activeRouter => _activeRouter;

  Future<RouterOsClient> connectTo(
    SavedRouter router, {
    bool acceptInvalidCertificate = false,
  }) async {
    final candidate = RouterOsClient(
      host: router.host,
      port: router.port,
      username: router.username,
      password: router.password,
      useSsl: router.useSsl,
      useRestApi: router.useRestApi,
      knockPorts: router.knockPorts,
      autoReconnect: true,
      onBadCertificate: acceptInvalidCertificate
          ? (certificate, host, port) => true
          : null,
    );

    try {
      await candidate.connect();
    } catch (_) {
      await candidate.close();
      rethrow;
    }

    final previous = state;
    state = candidate;
    _activeRouter = router;

    if (previous != null && !identical(previous, candidate)) {
      await previous.close();
    }
    return candidate;
  }

  Future<void> disconnectIfRouter(String id) async {
    if (_activeRouter?.id == id) await disconnect();
  }

  Future<void> disconnect() async {
    final previous = state;
    state = null;
    _activeRouter = null;
    if (previous != null) await previous.close();
  }

  @override
  void dispose() {
    final client = state;
    state = null;
    _activeRouter = null;
    if (client != null) unawaited(client.close());
    super.dispose();
  }
}

/// Dedicated interface for state-changing or one-shot commands. It remains
/// separate from the live-read service even though both use the tagged socket.
final routerCommandExecutorProvider = Provider<RouterCommandExecutor?>((ref) {
  final client = ref.watch(activeRouterClientProvider);
  return client == null ? null : RouterCommandExecutor(client);
});

class RouterCommandExecutor {
  const RouterCommandExecutor(this._client);

  final RouterOsClient _client;

  Future<List<Map<String, String>>> execute(
    String path, {
    Map<String, String> args = const <String, String>{},
    Duration? timeout,
  }) {
    return _client.command(path, args: args, timeout: timeout);
  }
}

/// Dedicated interface for subscriptions and frequently refreshed read data.
///
/// RouterOS exposes some data as streaming commands (such as interface
/// traffic); other resources are refreshed by polling their print command.
final routerLiveReadServiceProvider = Provider<RouterLiveReadService?>((ref) {
  final client = ref.watch(activeRouterClientProvider);
  return client == null ? null : RouterLiveReadService(client);
});

class RouterLiveReadService {
  const RouterLiveReadService(this._client);

  final RouterOsClient _client;

  Stream<Map<String, String>> watchResources({
    Duration interval = const Duration(seconds: 2),
  }) async* {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'Interval must be positive');
    }
    while (true) {
      final rows = await _client.command('/system/resource/print');
      if (rows.isNotEmpty) {
        yield Map<String, String>.unmodifiable(rows.first);
      }
      await Future<void>.delayed(interval);
    }
  }

  Stream<Map<String, String>> watchIdentity({
    Duration interval = const Duration(seconds: 10),
  }) async* {
    if (interval <= Duration.zero) {
      throw ArgumentError.value(interval, 'interval', 'Interval must be positive');
    }
    while (true) {
      final rows = await _client.command('/system/identity/print');
      if (rows.isNotEmpty) {
        yield Map<String, String>.unmodifiable(rows.first);
      }
      await Future<void>.delayed(interval);
    }
  }

  Stream<Map<String, String>> watchInterfaceTraffic(String interfaceName) {
    if (interfaceName.trim().isEmpty) {
      return Stream<Map<String, String>>.error(
        ArgumentError.value(interfaceName, 'interfaceName', 'Interface name cannot be empty'),
      );
    }
    return _client.monitorStream(
      '/interface/monitor-traffic',
      args: <String, String>{'interface': interfaceName},
    );
  }
}
