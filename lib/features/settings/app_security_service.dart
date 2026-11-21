import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/storage/router_storage_service.dart';

/// Secure app settings and authenticated encryption for router exports.
abstract final class AppSecurityService {

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _pinSaltKey = 'nova.app.pin.salt.v1';
  static const String _pinHashKey = 'nova.app.pin.hash.v1';
  static const String _refreshIntervalKey = 'nova.stream.refresh.interval.v1';
  static const String _pinFailureCountKey = 'nova.app.pin.failures.v1';
  static const String _pinLockoutUntilKey = 'nova.app.pin.lockout.until.v1';
  static const int _pinIterations = 80000;
  static const int _backupIterations = 180000;
  static final AesGcm _cipher = AesGcm.with256bits();

  static List<int> _randomBytes(int count) =>
      List<int>.generate(count, (_) => Random.secure().nextInt(256));

  static Future<SecretKey> _deriveKey(
    String password,
    List<int> salt, {
    required int iterations,
  }) {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static Future<bool> isPinEnabled() async {
    final salt = await _storage.read(key: _pinSaltKey);
    final hash = await _storage.read(key: _pinHashKey);
    return salt != null && hash != null && salt.isNotEmpty && hash.isNotEmpty;
  }

  static Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      throw const FormatException('يجب أن يتكون رمز PIN من 4 إلى 8 أرقام.');
    }
    final salt = _randomBytes(16);
    final key = await _deriveKey(pin, salt, iterations: _pinIterations);
    final hash = await key.extractBytes();
    await _storage.write(key: _pinSaltKey, value: base64Encode(salt));
    await _storage.write(key: _pinHashKey, value: base64Encode(hash));
    await clearPinFailures();
  }

  static Future<bool> verifyPin(String pin) async {
    if (await getPinLockoutRemaining() != null) return false;
    final saltEncoded = await _storage.read(key: _pinSaltKey);
    final hashEncoded = await _storage.read(key: _pinHashKey);
    if (saltEncoded == null || hashEncoded == null) return false;
    try {
      final salt = base64Decode(saltEncoded);
      final expected = base64Decode(hashEncoded);
      final key = await _deriveKey(pin, salt, iterations: _pinIterations);
      final actual = await key.extractBytes();
      final matches = _constantTimeEquals(actual, expected);
      if (matches) {
        try {
          await clearPinFailures();
        } catch (_) {
          // A correct PIN must still unlock if cleanup storage is temporarily unavailable.
        }
      } else {
        await _recordPinFailure();
      }
      return matches;
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearPin() async {
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _pinHashKey);
    await clearPinFailures();
  }

  static Future<Duration?> getPinLockoutRemaining() async {
    final raw = await _storage.read(key: _pinLockoutUntilKey);
    final timestamp = int.tryParse(raw ?? '');
    if (timestamp == null) return null;
    final remaining = DateTime.fromMillisecondsSinceEpoch(timestamp).difference(DateTime.now());
    if (remaining <= Duration.zero) {
      await _storage.delete(key: _pinLockoutUntilKey);
      return null;
    }
    return remaining;
  }

  static Future<void> _recordPinFailure() async {
    final raw = await _storage.read(key: _pinFailureCountKey);
    final previous = int.tryParse(raw ?? '') ?? 0;
    final count = (previous < 0 ? 0 : previous) + 1;
    final boundedCount = count > 15 ? 15 : count;
    await _storage.write(key: _pinFailureCountKey, value: boundedCount.toString());
    final lockout = PinAttemptPolicy.lockoutForFailureCount(boundedCount);
    if (lockout == null) return;
    final lockoutUntil = DateTime.now().add(lockout).millisecondsSinceEpoch;
    await _storage.write(key: _pinLockoutUntilKey, value: lockoutUntil.toString());
  }

  static Future<void> clearPinFailures() async {
    await _storage.delete(key: _pinFailureCountKey);
    await _storage.delete(key: _pinLockoutUntilKey);
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var mismatch = 0;
    for (var i = 0; i < a.length; i++) {
      mismatch |= a[i] ^ b[i];
    }
    return mismatch == 0;
  }

  static Future<int> getRefreshInterval() async {
    final raw = await _storage.read(key: _refreshIntervalKey);
    final value = int.tryParse(raw ?? '');
    return <int>[1, 2, 5].contains(value) ? value! : 1;
  }

  static Future<void> setRefreshInterval(int seconds) async {
    if (!<int>[1, 2, 5].contains(seconds)) {
      throw ArgumentError.value(seconds, 'seconds', 'الفاصل المسموح 1 أو 2 أو 5 ثوانٍ.');
    }
    await _storage.write(key: _refreshIntervalKey, value: seconds.toString());
  }

  /// Exported JSON contains an authenticated AES-256-GCM envelope, not plaintext credentials.
  static Future<List<int>> encryptRouterBackup(
    List<SavedRouter> routers,
    String password,
  ) async {
    if (password.length < 8) {
      throw const FormatException('كلمة مرور النسخة يجب ألا تقل عن 8 أحرف.');
    }
    final salt = _randomBytes(16);
    final key = await _deriveKey(password, salt, iterations: _backupIterations);
    final clearText = utf8.encode(jsonEncode(<String, Object?>{
      'format': 'nova-router-backup',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'routers': routers.map((router) => router.toJson()).toList(),
    }));
    final encrypted = await _cipher.encrypt(clearText, secretKey: key);
    final envelope = <String, Object?>{
      'format': 'nova-router-backup-encrypted',
      'version': 1,
      'cipher': 'AES-256-GCM',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': _backupIterations,
      'salt': base64Encode(salt),
      'nonce': base64Encode(encrypted.nonce),
      'ciphertext': base64Encode(encrypted.cipherText),
      'mac': base64Encode(encrypted.mac.bytes),
    };
    return utf8.encode(jsonEncode(envelope));
  }

  static Future<List<SavedRouter>> decryptRouterBackup(
    List<int> fileBytes,
    String password,
  ) async {
    try {
      final decoded = jsonDecode(utf8.decode(fileBytes));
      if (decoded is! Map<String, dynamic> ||
          decoded['format'] != 'nova-router-backup-encrypted' ||
          decoded['version'] != 1 ||
          decoded['cipher'] != 'AES-256-GCM' ||
          decoded['kdf'] != 'PBKDF2-HMAC-SHA256' ||
          decoded['iterations'] != _backupIterations) {
        throw const FormatException('تنسيق النسخة الاحتياطية غير مدعوم.');
      }
      final salt = base64Decode(decoded['salt'] as String);
      final nonce = base64Decode(decoded['nonce'] as String);
      final ciphertext = base64Decode(decoded['ciphertext'] as String);
      final macBytes = base64Decode(decoded['mac'] as String);
      if (salt.length != 16 || nonce.length != _cipher.nonceLength || macBytes.length != 16) {
        throw const FormatException('بيانات التشفير غير صالحة.');
      }
      final key = await _deriveKey(password, salt, iterations: _backupIterations);
      final clear = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(macBytes)),
        secretKey: key,
      );
      final document = jsonDecode(utf8.decode(clear));
      if (document is! Map<String, dynamic> ||
          document['format'] != 'nova-router-backup' ||
          document['version'] != 1 ||
          document['routers'] is! List<dynamic>) {
        throw const FormatException('محتوى النسخة غير صالح.');
      }
      final routers = (document['routers'] as List<dynamic>).map((entry) {
        if (entry is! Map<String, dynamic>) {
          throw const FormatException('يوجد سجل راوتر غير صالح داخل النسخة.');
        }
        return SavedRouter.fromJson(entry);
      }).toList(growable: false);
      if (routers.map((router) => router.id).toSet().length != routers.length) {
        throw const FormatException('النسخة تحتوي على معرّفات راوتر مكررة.');
      }
      return routers;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('تعذر فك التشفير. تأكد من كلمة المرور وسلامة الملف.');
    }
  }
}

/// Progressive delay applied after repeated failed local PIN checks.
abstract final class PinAttemptPolicy {
  static Duration? lockoutForFailureCount(int failureCount) {
    if (failureCount < 5) return null;
    if (failureCount < 10) return const Duration(seconds: 30);
    if (failureCount < 15) return const Duration(minutes: 2);
    return const Duration(minutes: 5);
  }
}

/// PIN gate shown at startup and after a prolonged background interval.
typedef PinEnabledReader = Future<bool> Function();

class AppPinGate extends StatefulWidget {
  const AppPinGate({
    super.key,
    required this.child,
    this.pinEnabledReader,
  });

  final Widget child;
  final PinEnabledReader? pinEnabledReader;

  Future<bool> _readPinEnabled() =>
      pinEnabledReader?.call() ?? AppSecurityService.isPinEnabled();

  @override
  State<AppPinGate> createState() => _AppPinGateState();
}

class _AppPinGateState extends State<AppPinGate> with WidgetsBindingObserver {
  final TextEditingController _pinController = TextEditingController();
  bool _ready = false;
  bool _pinEnabled = false;
  bool _unlocked = false;
  bool _busy = false;
  bool _storageUnavailable = false;
  String? _error;
  DateTime? _backgroundedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadLockState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _loadLockState() async {
    try {
      final enabled = await widget._readPinEnabled();
      if (!mounted) return;
      setState(() {
        _pinEnabled = enabled;
        _unlocked = !enabled;
        _ready = true;
        _storageUnavailable = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        // Never expose router controls when the lock state cannot be read.
        _pinEnabled = true;
        _unlocked = false;
        _ready = true;
        _storageUnavailable = true;
        _error = 'تعذر قراءة حالة قفل التطبيق من التخزين الآمن. التطبيق مقفل احتياطياً.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _backgroundedAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_checkAfterResume());
    }
  }

  Future<void> _checkAfterResume() async {
    final pausedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (pausedAt == null || DateTime.now().difference(pausedAt) < const Duration(seconds: 20)) return;
    try {
      final enabled = await widget._readPinEnabled();
      if (!mounted) return;
      setState(() {
        _pinEnabled = enabled;
        _unlocked = !enabled;
        _storageUnavailable = false;
        _error = null;
        _pinController.clear();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        // A storage failure on resume must also keep the app behind the lock.
        _pinEnabled = true;
        _unlocked = false;
        _storageUnavailable = true;
        _error = 'تعذر التحقق من حالة القفل بعد العودة. التطبيق مقفل احتياطياً.';
        _pinController.clear();
      });
    }
  }

  Future<void> _unlock() async {
    if (_busy || _storageUnavailable) return;
    setState(() { _busy = true; _error = null; });
    try {
      final remaining = await AppSecurityService.getPinLockoutRemaining();
      if (remaining != null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = 'المحاولات موقوفة مؤقتاً. أعد المحاولة بعد ${remaining.inSeconds.ceil()} ثانية.';
        });
        return;
      }
      final valid = await AppSecurityService.verifyPin(_pinController.text);
      final lockout = valid ? null : await AppSecurityService.getPinLockoutRemaining();
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (valid) {
          _unlocked = true;
          _error = null;
          _pinController.clear();
        } else if (lockout != null) {
          _error = 'تم إيقاف المحاولات لمدة ${lockout.inSeconds.ceil()} ثانية.';
        } else {
          _error = 'رمز PIN غير صحيح.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'تعذر التحقق من PIN عبر التخزين الآمن.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        backgroundColor: Color(0xFF080B12),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF8B7CFF))),
      );
    }
    if (!_pinEnabled || _unlocked) return widget.child;
    return Scaffold(
      backgroundColor: const Color(0xFF080B12),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 78, height: 78,
                decoration: BoxDecoration(
                  color: const Color(0xFF8B7CFF).withOpacity(.16),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: const Icon(Icons.lock_outline_rounded, color: Color(0xFF8B7CFF), size: 40),
              ),
              const SizedBox(height: 20),
              const Text('NOVA SECURITY LOCK', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              const Text('أدخل رمز PIN لفتح التطبيق', style: TextStyle(color: Color(0xFF8D9AB0))),
              const SizedBox(height: 22),
              TextField(
                controller: _pinController,
                autofocus: true,
                obscureText: true,
                maxLength: 8,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _unlock(),
                style: const TextStyle(color: Colors.white, letterSpacing: 8, fontSize: 20),
                decoration: const InputDecoration(labelText: 'PIN (4–8 أرقام)', counterText: ''),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Color(0xFFFF657A))),
              ],
              if (_storageUnavailable) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _busy ? null : _loadLockState,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy || _storageUnavailable ? null : _unlock,
                  icon: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.lock_open_rounded),
                  label: const Text('فتح التطبيق'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
