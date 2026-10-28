import 'dart:async';

import 'routeros_client.dart';

/// Capabilities discovered from the connected RouterOS device, not guessed
/// from the configured transport.
class RouterOsCapabilities {
  const RouterOsCapabilities({
    required this.version,
    required this.majorVersion,
    required this.rest,
    required this.api,
    required this.wireless,
    required this.wifi,
    required this.wireguard,
  });

  final String version;
  final int majorVersion;
  final bool rest;
  final bool api;
  final bool wireless;
  final bool wifi;
  final bool wireguard;

  bool get supportsV7 => majorVersion >= 7;
}

/// Shared compatibility layer for RouterOS 6 and 7. Construct this only after
/// the transport has authenticated. A feature is exposed only after its menu
/// can be queried successfully.
class RouterOsCompatibility {
  RouterOsCompatibility(this.client);

  final RouterOsClient client;
  RouterOsCapabilities? _capabilities;
  RouterOsCapabilities? get capabilities => _capabilities;

  Future<RouterOsCapabilities> discover() async {
    try {
      final rows = await client.command('/system/resource/print');
      if (rows.isEmpty) {
        throw const RouterOsException('لم يُرجع الراوتر معلومات إصدار RouterOS.');
      }
      final version = rows.first['version'] ?? '';
      final match = RegExp(r'^(\d+)').firstMatch(version);
      final major = int.tryParse(match?.group(1) ?? '');
      if (major == null) {
        throw RouterOsException('تعذر قراءة إصدار RouterOS: $version');
      }

      final wireless = await _exists('/interface/wireless/print');
      final wifi = await _exists('/interface/wifi/print') ||
          await _exists('/interface/wifiwave2/print');
      final wireguard = await _exists('/interface/wireguard/print');

      _capabilities = RouterOsCapabilities(
        version: version,
        majorVersion: major,
        rest: major >= 7 && client.useRestApi,
        api: !client.useRestApi,
        wireless: wireless,
        wifi: wifi,
        wireguard: wireguard,
      );
      return _capabilities!;
    } on TimeoutException {
      throw const RouterOsException('انتهت مهلة الاتصال أثناء اكتشاف إصدار الراوتر.');
    } on RouterOsException {
      rethrow;
    } catch (error) {
      throw RouterOsException(_arabicError(error));
    }
  }

  Future<bool> _exists(String path) async {
    try {
      await client.command(path, timeout: const Duration(seconds: 5));
      return true;
    } on TimeoutException {
      return false;
    } on RouterOsException catch (error) {
      final text = error.message.toLowerCase();
      if (text.contains('not enough permissions') ||
          text.contains('permission') ||
          text.contains('صلاح')) {
        throw const RouterOsException('صلاحيات الحساب لا تسمح باكتشاف قدرات الراوتر.');
      }
      return false;
    }
  }

  /// Writes are never reported as successful until a fresh read matches every
  /// requested field. [readBack] must query the exact object after the write.
  Future<Map<String, String>> writeAndVerify({
    required Future<void> Function() write,
    required Future<Map<String, String>?> Function() readBack,
    required Map<String, String> expected,
  }) async {
    try {
      await write();
      final actual = await readBack();
      if (actual == null ||
          expected.entries.any((entry) => actual[entry.key] != entry.value)) {
        throw const RouterOsException(
          'أُرسل التغيير لكن لم يؤكده الراوتر عند إعادة القراءة؛ لم يتم عرض نجاح.',
        );
      }
      return actual;
    } on TimeoutException {
      throw const RouterOsException('انتهت المهلة؛ تعذّر التأكد من تطبيق التغيير.');
    } on RouterOsException catch (error) {
      final message = error.message.toLowerCase();
      if (message.contains('not enough permissions') ||
          message.contains('permission denied') ||
          message.contains('صلاح')) {
        throw const RouterOsException('فشل التغيير: صلاحيات حساب الراوتر غير كافية.');
      }
      if (message.contains('not supported') || message.contains('unsupported')) {
        throw const RouterOsException('هذه العملية غير مدعومة في إصدار RouterOS الحالي.');
      }
      rethrow;
    } catch (error) {
      throw RouterOsException(_arabicError(error));
    }
  }

  String _arabicError(Object error) {
    if (error is TimeoutException) return 'انتهت مهلة الاتصال بالراوتر.';
    final value = error.toString().toLowerCase();
    if (value.contains('permission') || value.contains('not enough privileges')) {
      return 'صلاحيات حساب الراوتر غير كافية لتنفيذ العملية.';
    }
    if (value.contains('unsupported') || value.contains('not supported')) {
      return 'العملية غير مدعومة على إصدار RouterOS المتصل.';
    }
    return 'تعذر تنفيذ العملية على الراوتر: $error';
  }
}
