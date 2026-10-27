import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A saved MikroTik RouterOS connection profile.
///
/// Passwords are serialized only into FlutterSecureStorage and must never be
/// written to logs or ordinary preferences.
class SavedRouter {
  const SavedRouter({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.useSsl,
    this.useRestApi = false,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String password;
  final bool useSsl;
  final bool useRestApi;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'password': password,
        'useSsl': useSsl,
        'useRestApi': useRestApi,
      };

  factory SavedRouter.fromJson(Map<String, dynamic> json) {
    String requiredString(String key) {
      final value = json[key];
      if (value is! String) {
        throw FormatException('Saved router field "$key" is invalid.');
      }
      return value;
    }

    final rawPort = json['port'];
    final parsedPort = rawPort is int ? rawPort : int.tryParse('$rawPort');
    final rawSsl = json['useSsl'];
    final rawRest = json['useRestApi'] ?? false;

    if (parsedPort == null || parsedPort < 1 || parsedPort > 65535) {
      throw const FormatException('Saved router port is invalid.');
    }
    if (rawSsl is! bool || rawRest is! bool) {
      throw const FormatException('Saved router SSL setting is invalid.');
    }

    return SavedRouter(
      id: requiredString('id'),
      name: requiredString('name'),
      host: requiredString('host'),
      port: parsedPort,
      username: requiredString('username'),
      password: requiredString('password'),
      useSsl: rawSsl,
      useRestApi: rawRest,
    );
  }

  SavedRouter copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    String? password,
    bool? useSsl,
    bool? useRestApi,
  }) {
    return SavedRouter(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      password: password ?? this.password,
      useSsl: useSsl ?? this.useSsl,
      useRestApi: useRestApi ?? this.useRestApi,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedRouter &&
          other.id == id &&
          other.name == name &&
          other.host == host &&
          other.port == port &&
          other.username == username &&
          other.password == password &&
          other.useSsl == useSsl &&
          other.useRestApi == useRestApi;

  @override
  int get hashCode =>
      Object.hash(id, name, host, port, username, password, useSsl, useRestApi);
}

/// Encrypted persistence for saved router profiles.
///
/// FlutterSecureStorage encrypts the value using the platform's secure
/// storage implementation. The whole router list is stored as a JSON array
/// under one versioned key.
class RouterStorageService {
  RouterStorageService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _storageKey = 'nova.saved_routers.v1';
  final FlutterSecureStorage _storage;

  // Serializes read-modify-write operations to prevent concurrent edits from
  // overwriting one another.
  Future<void> _serialTail = Future<void>.value();

  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _serialTail = _serialTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<List<SavedRouter>> loadRouters() =>
      _runSerialized<List<SavedRouter>>(_readAll);

  Future<List<SavedRouter>> saveRouter(SavedRouter router) {
    return _runSerialized<List<SavedRouter>>(() async {
      final routers = await _readAll();
      final index = routers.indexWhere((item) => item.id == router.id);
      if (index < 0) {
        routers.add(router);
      } else {
        routers[index] = router;
      }
      await _writeAll(routers);
      return List<SavedRouter>.unmodifiable(routers);
    });
  }

  Future<List<SavedRouter>> deleteRouter(String id) {
    return _runSerialized<List<SavedRouter>>(() async {
      final routers = await _readAll();
      routers.removeWhere((router) => router.id == id);
      await _writeAll(routers);
      return List<SavedRouter>.unmodifiable(routers);
    });
  }

  Future<void> replaceAll(List<SavedRouter> routers) {
    return _runSerialized<void>(() => _writeAll(routers));
  }

  Future<List<SavedRouter>> _readAll() async {
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null || encoded.isEmpty) return <SavedRouter>[];

    final decoded = jsonDecode(encoded);
    if (decoded is! List<dynamic>) {
      throw const FormatException('Encrypted router data is not a JSON list.');
    }

    return decoded.map((entry) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Encrypted router data contains an invalid item.');
      }
      return SavedRouter.fromJson(entry);
    }).toList(growable: true);
  }

  Future<void> _writeAll(List<SavedRouter> routers) {
    final value = jsonEncode(routers.map((router) => router.toJson()).toList());
    return _storage.write(key: _storageKey, value: value);
  }

  /// Measures TCP connection latency to the RouterOS API port.
  ///
  /// Returns elapsed milliseconds (fractional values are retained), or null
  /// when the host is offline, the port is closed, or the timeout expires.
  static Future<double?> checkPing(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (host.trim().isEmpty || port < 1 || port > 65535) return null;

    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(host.trim(), port, timeout: timeout);
      stopwatch.stop();
      return stopwatch.elapsedMicroseconds / 1000.0;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    } finally {
      socket?.destroy();
    }
  }
}
