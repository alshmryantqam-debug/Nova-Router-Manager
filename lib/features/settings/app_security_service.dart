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
  }

  static Future<bool> verifyPin(String pin) async {
    final saltEncoded = await _storage.read(key: _pinSaltKey);
    final hashEncoded = await _storage.read(key: _pinHashKey);
    if (saltEncoded == null || hashEncoded == null) return false;
    try {
      final salt = base64Decode(saltEncoded);
      final expected = base64Decode(hashEncoded);
      final key = await _deriveKey(pin, salt, iterations: _pinIterations);
      final actual = await key.extractBytes();
      return _constantTimeEquals(actual, expected);
    } catch (_) {
      return false;
    }
  }

  static Future<void> clearPin() async {
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _pinHashKey);
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

/// PIN gate shown at startup and after a prolonged background interval.
class AppPinGate extends StatefulWidget {
  const AppPinGate({super.key, required this.child});
  final Widget child;

  @override
  State<AppPinGate> createState() => _AppPinGateState();
}

class _AppPinGateState extends State<AppPinGate> with WidgetsBindingObserver {
  final TextEditingController _pinController = TextEditingController();
  bool _ready = false;
  bool _pinEnabled = false;
  bool _unlocked = false;
  bool _busy = false;
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
    var enabled = false;
    try { enabled = await AppSecurityService.isPinEnabled(); } catch (_) { enabled = false; }
    if (!mounted) return;
    setState(() {
      _pinEnabled = enabled;
      _unlocked = !enabled;
      _ready = true;
    });
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
    final enabled = await AppSecurityService.isPinEnabled();
    if (!mounted) return;
    setState(() {
      _pinEnabled = enabled;
      _unlocked = !enabled;
      _error = null;
      _pinController.clear();
    });
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    final valid = await AppSecurityService.verifyPin(_pinController.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (valid) {
        _unlocked = true;
        _error = null;
        _pinController.clear();
      } else {
        _error = 'رمز PIN غير صحيح.';
      }
    });
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
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _unlock,
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
