import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

/// A RouterOS API socket client supporting concurrent tagged requests and streams.
///
/// RouterOS API uses TCP/8728 by default and API-SSL on TCP/8729.
/// For self-signed certificates, provide [onBadCertificate] explicitly. Accepting
/// an untrusted certificate disables normal certificate validation for that peer;
/// use it only on a trusted management network.
class RouterOsClient {
  RouterOsClient({
    required this.host,
    required this.username,
    required this.password,
    this.port = 8728,
    this.useSsl = false,
    this.useRestApi = false,
    this.connectionTimeout = const Duration(seconds: 8),
    this.requestTimeout = const Duration(seconds: 20),
    this.reconnectInterval = const Duration(seconds: 5),
    this.heartbeatInterval = const Duration(seconds: 30),
    this.autoReconnect = true,
    this.onBadCertificate,
  }) {
    if (host.trim().isEmpty) {
      throw ArgumentError.value(host, 'host', 'Host cannot be empty');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'Port must be between 1 and 65535');
    }
    if (autoReconnect) {
      _reconnectTimer = Timer.periodic(reconnectInterval, (_) {
        if (!_disposed && !_connected && _connectFuture == null) {
          unawaited(connect().catchError((Object _) {}));
        }
      });
    }
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (!_disposed && _connected && _authenticated) {
        unawaited(command('/system/identity/print').then<void>((_) {}).catchError((Object _) {}));
      }
    });
  }

  final String host;
  final String username;
  final String password;
  final int port;
  final bool useSsl;
  final bool useRestApi;
  final Duration connectionTimeout;
  final Duration requestTimeout;
  final Duration reconnectInterval;
  final Duration heartbeatInterval;
  final bool autoReconnect;

  /// Return true only when the presented certificate is intentionally trusted.
  /// This callback is consulted only for TLS connections with an invalid chain.
  final bool Function(X509Certificate certificate, String host, int port)?
      onBadCertificate;

  Socket? _socket;
  HttpClient? _restHttpClient;
  String? _authPendingTag;
  StreamSubscription<List<int>>? _socketSubscription;
  Future<void>? _connectFuture;
  final List<int> _incoming = <int>[];
  final Map<String, _PendingRequest> _pending = <String, _PendingRequest>{};
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  int _nextTag = 0;
  bool _connected = false;
  bool _authenticated = false;
  bool _disposed = false;

  bool get isConnected => _connected;
  bool get isAuthenticated => _authenticated;

  /// Establishes the socket and authenticates. Concurrent calls share one attempt.
  Future<void> connect() {
    if (_disposed) {
      return Future<void>.error(StateError('RouterOS client is closed'));
    }
    if (_connected && _authenticated) return Future<void>.value();
    final existing = _connectFuture;
    if (existing != null) return existing;

    final future = _connectInternal();
    _connectFuture = future;
    return future.whenComplete(() {
      if (identical(_connectFuture, future)) _connectFuture = null;
    });
  }

  Future<void> _connectInternal() async {
    await _closeSocketOnly();
    if (useRestApi) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..badCertificateCallback = (certificate, host, port) =>
            onBadCertificate?.call(certificate, host, port) ?? false;
      _restHttpClient = client;
      _connected = true;
      try {
        final response = await _restRequest('GET', '/system/identity')
            .timeout(requestTimeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw RouterOsException('REST API رفض تسجيل الدخول (HTTP ${response.statusCode}).');
        }
        _authenticated = true;
        return;
      } catch (error) {
        _connected = false;
        _authenticated = false;
        client.close(force: true);
        _restHttpClient = null;
        if (error is TimeoutException) {
          throw TimeoutException('تم فتح اتصال REST لكن لم يكتمل رد تسجيل الدخول', requestTimeout);
        }
        rethrow;
      }
    }
    try {
      final Socket socket;
      if (useSsl) {
        socket = await SecureSocket.connect(
          host,
          port,
          timeout: connectionTimeout,
          onBadCertificate: (certificate) =>
              onBadCertificate?.call(certificate, host, port) ?? false,
        );
      } else {
        socket = await Socket.connect(host, port, timeout: connectionTimeout);
      }

      if (_disposed) {
        socket.destroy();
        throw StateError('RouterOS client is closed');
      }

      _socket = socket;
      _incoming.clear();
      _connected = true;
      _authenticated = false;
      _socketSubscription = socket.listen(
        _onBytes,
        onError: (Object error, StackTrace stack) => _handleDisconnect(error),
        onDone: () => _handleDisconnect(
          const SocketException('RouterOS connection closed by remote host'),
        ),
        cancelOnError: false,
      );

      await _authenticate().timeout(
        requestTimeout,
        onTimeout: () => throw TimeoutException(
          'تم فتح المنفذ ${port} لكن لم يكتمل رد تسجيل الدخول',
          requestTimeout,
        ),
      );
      _authenticated = true;
    } catch (_) {
      _connected = false;
      _authenticated = false;
      await _closeSocketOnly();
      rethrow;
    }
  }

  Future<void> _authenticate() async {
    // RouterOS 6.43+ and RouterOS 7 support this login form.
    // Login is deliberately untagged: some RouterOS versions omit .tag on
    // authentication replies. The reader routes those replies to this waiter.
    final result = await _sendRequest(
      '/login',
      <String, String>{'name': username, 'password': password},
      timeout: requestTimeout,
      authenticateRequest: true,
      addTag: false,
    );
    final challenge = result.firstOrNull?['ret'];
    if (challenge != null && challenge.isNotEmpty) {
      final challengeBytes = <int>[0, ...utf8.encode(password), ..._hexBytes(challenge)];
      final digest = crypto.md5.convert(challengeBytes).bytes;
      final response = '00${digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
      final legacy = await _sendRequest(
        '/login',
        <String, String>{'name': username, 'response': response},
        timeout: requestTimeout,
        authenticateRequest: true,
        addTag: false,
      );
      if (legacy.any((row) => row['ret'] != null)) {
        throw const RouterOsException('فشل تسجيل الدخول بطريقة challenge-response القديمة.');
      }
    }
  }

  /// Executes a one-shot API command and returns each !re row as a map.
  /// Arguments use bare names, e.g. {'numbers': '0', '.proplist': 'name,uptime'}.
  Future<List<Map<String, String>>> command(
    String path, {
    Map<String, String> args = const <String, String>{},
    Duration? timeout,
  }) async {
    _ensureUsable();
    return _sendRequest(path, args, timeout: timeout ?? requestTimeout);
  }

  /// Starts a long-lived API request. Rows are delivered independently by .tag,
  /// so multiple subscriptions and ordinary commands can share the same socket.
  ///
  /// Example: monitorStream('/interface/monitor-traffic',
  /// args: {'interface': 'ether1', 'once': 'false'}).
  Stream<Map<String, String>> monitorStream(
    String path, {
    Map<String, String> args = const <String, String>{},
  }) {
    _ensureUsable();
    final tag = _newTag();
    final controller = StreamController<Map<String, String>>(
      onCancel: () => _cancelStream(tag),
    );
    _pending[tag] = _PendingRequest(streamController: controller);
    try {
      unawaited(_writeSentence(_buildSentence(path, args, tag)).catchError((Object error, StackTrace stack) { _pending.remove(tag); if (!controller.isClosed) controller.addError(error, stack); }));
    } catch (error, stack) {
      _pending.remove(tag);
      controller.addError(error, stack);
      unawaited(controller.close());
    }
    return controller.stream;
  }

  Future<void> _cancelStream(String targetTag) async {
    if (!_connected || !_authenticated || _disposed) {
      _pending.remove(targetTag);
      return;
    }
    try {
      // The =tag word identifies the stream being cancelled; .tag identifies
      // this separate cancellation request and prevents response cross-talk.
      await _sendRequest(
        '/cancel',
        <String, String>{'tag': targetTag},
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {
      // Closing a local subscription must remain safe during a disconnect.
    } finally {
      final pending = _pending.remove(targetTag);
      if (pending?.streamController != null &&
          !pending!.streamController!.isClosed) {
        await pending.streamController!.close();
      }
    }
  }

  Future<List<Map<String, String>>> _sendRequest(
    String path,
    Map<String, String> args, {
    required Duration timeout,
    bool authenticateRequest = false,
    bool addTag = true,
  }) async {
    if (!_connected || (!authenticateRequest && !_authenticated)) {
      await connect();
    }
    if (useRestApi) {
      final method = path.endsWith('/print') || path.endsWith('/get') ? 'GET' : 'GET';
      final resource = _restResource(path);
      final response = await _restRequest(method, resource, args: args).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RouterOsException('REST API HTTP ${response.statusCode}: ${response.body}');
      }
      final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
      if (decoded is List) {
        return decoded.whereType<Map>().map((row) => row.map((k, v) => MapEntry('$k', '$v'))).toList();
      }
      if (decoded is Map) return <Map<String, String>>[decoded.map((k, v) => MapEntry('$k', '$v'))];
      return <Map<String, String>>[];
    }
    if (!_connected || _socket == null) {
      throw const RouterOsException('RouterOS is not connected');
    }

    final tag = addTag ? _newTag() : 'login-${_nextTag++}';
    final completer = Completer<List<Map<String, String>>>();
    _pending[tag] = _PendingRequest(completer: completer, command: path, authentication: authenticateRequest);
    if (authenticateRequest) _authPendingTag = tag;
    try {
      await _writeSentence(_buildSentence(path, args, tag, addTag: addTag));
    } catch (error, stack) {
      _pending.remove(tag);
      completer.completeError(error, stack);
    }

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pending.remove(tag);
          throw TimeoutException('RouterOS command timed out: $path', timeout);
        },
      );
    } on RouterOsException {
      rethrow;
    } catch (_) {
      rethrow;
    }
  }

  List<String> _buildSentence(
    String path,
    Map<String, String> args,
    String tag, {
    bool addTag = true,
  }) {
    if (!path.startsWith('/')) {
      throw ArgumentError.value(path, 'path', 'API command must start with /');
    }
    final words = <String>[path];
    for (final entry in args.entries) {
      final key = entry.key.startsWith('=') ? entry.key.substring(1) : entry.key;
      if (key == '.tag') {
        throw ArgumentError('The .tag argument is managed by RouterOsClient');
      }
      words.add('=$key=${entry.value}');
    }
    if (addTag) words.add('=.tag=$tag');
    return words;
  }

  String _newTag() => 'nova-${_nextTag++}';

  Future<void> _writeSentence(List<String> words) async {
    final socket = _socket;
    if (!_connected || socket == null) {
      throw const SocketException('RouterOS socket is not connected');
    }
    final bytes = <int>[];
    for (final word in words) {
      final encoded = utf8.encode(word);
      bytes.addAll(_encodeLength(encoded.length));
      bytes.addAll(encoded);
    }
    bytes.add(0); // End of sentence.
    socket.add(bytes);
    await socket.flush();
  }

  void _onBytes(List<int> data) {
    _incoming.addAll(data);
    while (true) {
      final sentence = _tryReadSentence();
      if (sentence == null) return;
      _dispatchSentence(sentence);
    }
  }

  List<String>? _tryReadSentence() {
    final words = <String>[];
    var offset = 0;
    while (offset < _incoming.length) {
      final decoded = _decodeLength(_incoming, offset);
      if (decoded == null) return null;
      final length = decoded.$1;
      offset += decoded.$2;
      if (length == 0) {
        _incoming.removeRange(0, offset);
        return words;
      }
      if (_incoming.length < offset + length) return null;
      words.add(utf8.decode(
        _incoming.sublist(offset, offset + length),
        allowMalformed: true,
      ));
      offset += length;
    }
    return null;
  }

  (int, int)? _decodeLength(List<int> bytes, int offset) {
    if (offset >= bytes.length) return null;
    final first = bytes[offset];
    if ((first & 0x80) == 0) return (first, 1);
    if ((first & 0xC0) == 0x80) {
      if (bytes.length < offset + 2) return null;
      return (((first & 0x3F) << 8) | bytes[offset + 1], 2);
    }
    if ((first & 0xE0) == 0xC0) {
      if (bytes.length < offset + 3) return null;
      return (((first & 0x1F) << 16) |
          (bytes[offset + 1] << 8) |
          bytes[offset + 2], 3);
    }
    if ((first & 0xF0) == 0xE0) {
      if (bytes.length < offset + 4) return null;
      return (((first & 0x0F) << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3], 4);
    }
    if (first == 0xF0) {
      if (bytes.length < offset + 5) return null;
      return ((bytes[offset + 1] << 24) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 8) |
          bytes[offset + 4], 5);
    }
    throw const FormatException('Invalid RouterOS API length prefix');
  }

  List<int> _encodeLength(int length) {
    if (length < 0x80) return <int>[length];
    if (length < 0x4000) {
      return <int>[0x80 | (length >> 8), length & 0xFF];
    }
    if (length < 0x200000) {
      return <int>[
        0xC0 | (length >> 16),
        (length >> 8) & 0xFF,
        length & 0xFF,
      ];
    }
    if (length < 0x10000000) {
      return <int>[
        0xE0 | (length >> 24),
        (length >> 16) & 0xFF,
        (length >> 8) & 0xFF,
        length & 0xFF,
      ];
    }
    return <int>[
      0xF0,
      (length >> 24) & 0xFF,
      (length >> 16) & 0xFF,
      (length >> 8) & 0xFF,
      length & 0xFF,
    ];
  }

  void _dispatchSentence(List<String> words) {
    if (words.isEmpty) return;
    final kind = words.first;
    final fields = <String, String>{};
    for (final word in words.skip(1)) {
      if (word.startsWith('=')) {
        final separator = word.indexOf('=', 1);
        if (separator > 1) {
          fields[word.substring(1, separator)] = word.substring(separator + 1);
        }
      }
    }

    final tag = fields['.tag'] ?? _authPendingTag;
    if (tag == null) return;
    final pending = _pending[tag];
    if (pending == null) return;

    switch (kind) {
      case '!re':
        pending.rows.add(fields);
        final controller = pending.streamController;
        if (controller != null && !controller.isClosed) {
          controller.add(Map<String, String>.unmodifiable(fields));
        }
        break;
      case '!trap':
      case '!fatal':
        final error = RouterOsException(
          fields['message'] ?? 'RouterOS API error',
          category: fields['category'],
          command: pending.command,
        );
        _pending.remove(tag);
        if (_authPendingTag == tag) _authPendingTag = null;
        pending.fail(error);
        break;
      case '!done':
        _pending.remove(tag);
        if (_authPendingTag == tag) _authPendingTag = null;
        pending.complete();
        break;
      default:
        break;
    }
  }

  void _handleDisconnect(Object error) {
    if (!_connected && _socket == null) return;
    _connected = false;
    _authenticated = false;
    _socket = null;
    _restHttpClient?.close(force: true);
    _restHttpClient = null;
    _restHttpClient?.close(force: true);
    _restHttpClient = null;
    final subscription = _socketSubscription;
    _socketSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());

    final entries = _pending.entries.toList(growable: false);
    _pending.clear();
    for (final entry in entries) {
      entry.value.fail(
        RouterOsException('RouterOS connection lost: $error'),
      );
    }
    // The periodic reconnect timer reconnects automatically without creating
    // multiple simultaneous connection attempts.
  }

  void _ensureUsable() {
    if (_disposed) throw StateError('RouterOS client is closed');
  }

  Future<void> _closeSocketOnly() async {
    final subscription = _socketSubscription;
    _socketSubscription = null;
    if (subscription != null) {
      await subscription.cancel();
    }
    final socket = _socket;
    _socket = null;
    _connected = false;
    _authenticated = false;
    if (socket != null) {
      socket.destroy();
    }
  }

  List<int> _hexBytes(String hex) {
    final value = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (value.length.isOdd) throw const FormatException('Invalid login challenge');
    return <int>[
      for (var i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];
  }

  String _restResource(String path) {
    var value = path;
    if (value.endsWith('/print')) value = value.substring(0, value.length - 6);
    if (value.endsWith('/get')) value = value.substring(0, value.length - 4);
    return value.startsWith('/') ? value : '/$value';
  }

  Future<http.Response> _restRequest(
    String method,
    String resource, {
    Map<String, String> args = const <String, String>{},
  }) async {
    final scheme = useSsl ? 'https' : 'http';
    final webPort = port == 8728 ? (useSsl ? 443 : 80) : port;
    final uri = Uri(scheme: scheme, host: host, port: webPort, path: '/rest${_restResource(resource)}');
    final credentials = base64Encode(utf8.encode('$username:$password'));
    final request = await (_restHttpClient ?? HttpClient())
        .openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Basic $credentials');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (method == 'GET' && args.isNotEmpty) request.url.queryParameters;
    final response = await request.close();
    return http.Response.bytes(await response.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk)), response.statusCode, headers: response.headers);
  }

  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _heartbeatTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer = null;
    final entries = _pending.values.toList(growable: false);
    _pending.clear();
    for (final entry in entries) {
      entry.fail(const RouterOsException('RouterOS client was closed'));
    }
    await _closeSocketOnly();
  }
}

class _PendingRequest {
  _PendingRequest({
    this.completer,
    this.streamController,
    this.command,
    this.authentication = false,
  });

  final Completer<List<Map<String, String>>>? completer;
  final StreamController<Map<String, String>>? streamController;
  final String? command;
  final bool authentication;
  final List<Map<String, String>> rows = <Map<String, String>>[];

  void complete() {
    final controller = streamController;
    if (controller != null) {
      if (!controller.isClosed) unawaited(controller.close());
    } else if (completer != null && !completer!.isCompleted) {
      completer!.complete(List<Map<String, String>>.unmodifiable(rows));
    }
  }

  void fail(Object error) {
    final controller = streamController;
    if (controller != null) {
      if (!controller.isClosed) {
        controller.addError(error);
        unawaited(controller.close());
      }
    } else if (completer != null && !completer!.isCompleted) {
      completer!.completeError(error);
    }
  }
}

class RouterOsException implements Exception {
  const RouterOsException(this.message, {this.category, this.command});

  final String message;
  final String? category;
  final String? command;

  @override
  String toString() => 'RouterOsException: $message';
}
