import 'dart:async';
import '../../core/network/routeros_client.dart';

/// Live wireless, neighbor/ARP, and Ethernet PoE operations for RouterOS.
class WirelessTowersService {
  WirelessTowersService(this.client);
  final RouterOsClient client;

  Future<List<Map<String, String>>> wirelessInterfaces() =>
      client.command('/interface/wireless/print');

  Future<void> updateWirelessInterface({
    required String id,
    String? ssid,
    String? frequency,
    String? channelWidth,
  }) async {
    if (id.trim().isEmpty) throw const FormatException('معرّف واجهة اللاسلكي غير صالح.');
    final args = <String, String>{'.id': id};
    if (ssid != null) args['ssid'] = ssid.trim();
    if (frequency != null) {
      final value = frequency.trim();
      if (value.isEmpty || int.tryParse(value) == null) {
        throw const FormatException('أدخل التردد بالأرقام فقط، بوحدة MHz.');
      }
      args['frequency'] = value;
    }
    if (channelWidth != null && channelWidth.trim().isNotEmpty) {
      args['channel-width'] = channelWidth.trim();
    }
    if (args.length == 1) throw const FormatException('لا توجد تغييرات لحفظها.');
    await client.command('/interface/wireless/set', args: args);
  }

  Future<List<Map<String, String>>> registrationTable() =>
      client.command('/interface/wireless/registration-table/print');

  Future<List<Map<String, String>>> ethernetPoePorts() async {
    try {
      return await client.command('/interface/ethernet/poe/print');
    } catch (_) {
      // RouterOS may expose PoE controls only on supported Ethernet hardware.
      rethrow;
    }
  }

  Future<void> setPoeMode({required String id, required String mode}) async {
    if (!const <String>{'auto-on', 'off', 'forced-on'}.contains(mode)) {
      throw ArgumentError.value(mode, 'mode', 'وضع PoE غير مدعوم.');
    }
    await client.command('/interface/ethernet/poe/set',
        args: <String, String>{'.id': id, 'poe-out': mode});
  }

  /// Turns PoE off for five seconds, then restores the exact previous mode.
  /// The caller should require confirmation because it reboots the attached AP.
  Future<void> cyclePoe({required String id}) async {
    final rows = await ethernetPoePorts();
    final found = rows.where((row) => row['.id'] == id);
    if (found.isEmpty) throw StateError('لم يُعثر على منفذ PoE المحدد.');
    final original = (found.first['poe-out'] ?? '').trim();
    if (!const <String>{'auto-on', 'off', 'forced-on'}.contains(original)) {
      throw StateError('لا يمكن قراءة وضع PoE الحالي؛ أُلغيت العملية لتجنب تغيير الطاقة بصورة غير متوقعة.');
    }
    if (original == 'off') {
      throw StateError('تغذية PoE متوقفة أصلًا؛ غيّر الوضع إلى auto-on أو forced-on قبل إعادة التشغيل.');
    }
    await setPoeMode(id: id, mode: 'off');
    try {
      await Future<void>.delayed(const Duration(seconds: 5));
    } finally {
      await setPoeMode(id: id, mode: original);
    }
  }

  Future<List<Map<String, String>>> ipNeighbors() =>
      client.command('/ip/neighbor/print');

  Future<List<Map<String, String>>> arpEntries() =>
      client.command('/ip/arp/print');

  /// Combines neighbor discovery with ARP data, deduplicating by IP/MAC.
  Future<List<TowerDevice>> discoverDevices({int maxPings = 48}) async {
    final data = await Future.wait([
      ipNeighbors(),
      arpEntries(),
    ]);
    final byKey = <String, TowerDevice>{};
    for (final row in data[0]) {
      final address = _first(row, const ['address', 'ip-address']);
      final mac = _first(row, const ['mac-address', 'mac']);
      if (address.isEmpty && mac.isEmpty) continue;
      final key = address.isNotEmpty ? address : mac.toLowerCase();
      final old = byKey[key];
      byKey[key] = TowerDevice(
        ipAddress: address.isEmpty ? old?.ipAddress : address,
        macAddress: mac.isEmpty ? old?.macAddress : mac,
        interfaceName: _first(row, const ['interface', 'interface-name']).isEmpty
            ? old?.interfaceName ?? ''
            : _first(row, const ['interface', 'interface-name']),
        identity: _first(row, const ['identity', 'host-name', 'hostname']).isEmpty
            ? old?.identity ?? ''
            : _first(row, const ['identity', 'host-name', 'hostname']),
        platform: _first(row, const ['platform', 'board', 'version']).isEmpty
            ? old?.platform ?? ''
            : _first(row, const ['platform', 'board', 'version']),
        source: 'neighbor',
      );
    }
    for (final row in data[1]) {
      final address = _first(row, const ['address']);
      final mac = _first(row, const ['mac-address']);
      if (address.isEmpty && mac.isEmpty) continue;
      final key = address.isNotEmpty ? address : mac.toLowerCase();
      final old = byKey[key];
      byKey[key] = TowerDevice(
        ipAddress: address.isEmpty ? old?.ipAddress : address,
        macAddress: mac.isEmpty ? old?.macAddress : mac,
        interfaceName: _first(row, const ['interface']).isEmpty
            ? old?.interfaceName ?? ''
            : _first(row, const ['interface']),
        identity: old?.identity ?? '',
        platform: old?.platform ?? '',
        source: old == null ? 'arp' : 'neighbor + arp',
      );
    }

    final candidates = byKey.values
        .where((device) => _isIpv4(device.ipAddress))
        .take(maxPings)
        .toList(growable: false);
    final checks = <String, LinkPingResult>{};
    // Keep probe volume bounded and sequential to avoid flooding low-end routers.
    for (final device in candidates) {
      checks[device.ipAddress!] = await pingHost(device.ipAddress!, count: 4);
    }
    final all = byKey.values.map((device) => TowerDevice(
      ipAddress: device.ipAddress,
      macAddress: device.macAddress,
      interfaceName: device.interfaceName,
      identity: device.identity,
      platform: device.platform,
      source: device.source,
      ping: device.ipAddress == null ? null : checks[device.ipAddress],
    )).toList()
      ..sort((a, b) {
        final x = a.identity.isEmpty ? (a.ipAddress ?? a.macAddress ?? '') : a.identity;
        final y = b.identity.isEmpty ? (b.ipAddress ?? b.macAddress ?? '') : b.identity;
        return x.toLowerCase().compareTo(y.toLowerCase());
      });
    return all;
  }

  Future<LinkPingResult> pingHost(String address, {int count = 4}) async {
    final host = address.trim();
    if (!_isIpv4(host) && !RegExp(r'^[A-Za-z0-9.-]+$').hasMatch(host)) {
      throw const FormatException('عنوان الجهاز غير صالح لإجراء Ping.');
    }
    if (count < 1 || count > 10) throw const FormatException('عدد محاولات Ping يجب أن يكون من 1 إلى 10.');
    final rows = await client.command('/ping', args: <String, String>{
      'address': host,
      'count': '$count',
      'interval': '300ms',
    }, timeout: const Duration(seconds: 12));
    var replies = 0;
    var totalMs = 0.0;
    double? routerPacketLoss;
    for (final row in rows) {
      final time = _first(row, const ['time', 'avg-rtt', 'rtt']);
      final status = _first(row, const ['status']);
      final summaryLoss = _first(row, const ['packet-loss']);
      if (summaryLoss.isNotEmpty) {
        routerPacketLoss = _percent(summaryLoss);
      }
      final ms = _milliseconds(time);
      if (ms != null && !status.toLowerCase().contains('timeout')) {
        replies++;
        totalMs += ms;
      } else if (status.isEmpty && time.isEmpty) {
        final received = _first(row, const ['received']);
        final loss = _first(row, const ['packet-loss']);
        if (received.isNotEmpty) replies = int.tryParse(received) ?? replies;
        if (loss.isNotEmpty) routerPacketLoss = _percent(loss);
      }
    }
    final loss = routerPacketLoss ?? ((count - replies).clamp(0, count) * 100 / count);
    return LinkPingResult(
      host: host,
      latencyMs: replies == 0 ? null : totalMs / replies,
      packetLossPercent: loss.clamp(0, 100).toDouble(),
      replies: replies,
      attempts: count,
    );
  }

  static String _first(Map<String, String> row, List<String> keys) {
    for (final key in keys) {
      final value = (row[key] ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static bool _isIpv4(String? value) {
    if (value == null) return false;
    final parts = value.split('.');
    return parts.length == 4 && parts.every((part) {
      final n = int.tryParse(part);
      return n != null && n >= 0 && n <= 255;
    });
  }

  static double? _milliseconds(String raw) {
    if (raw.isEmpty || raw.toLowerCase().contains('timeout')) return null;
    final value = raw.trim().toLowerCase();
    final number = double.tryParse(value.replaceAll(RegExp(r'[^0-9.]'), ''));
    if (number == null) return null;
    if (value.contains('us') || value.contains('µs')) return number / 1000;
    if (value.contains('ms')) return number;
    if (value.contains('s')) return number * 1000;
    return number;
  }

  static double? _percent(String raw) {
    final value = double.tryParse(raw.replaceAll(RegExp(r'[^0-9.]'), ''));
    return value;
  }
}

class TowerDevice {
  const TowerDevice({
    required this.ipAddress,
    required this.macAddress,
    required this.interfaceName,
    required this.identity,
    required this.platform,
    required this.source,
    this.ping,
  });
  final String? ipAddress;
  final String? macAddress;
  final String interfaceName;
  final String identity;
  final String platform;
  final String source;
  final LinkPingResult? ping;
  String get displayName => identity.isNotEmpty ? identity : (platform.isNotEmpty ? platform : (ipAddress ?? macAddress ?? 'جهاز غير معروف'));
}

class LinkPingResult {
  const LinkPingResult({
    required this.host,
    required this.latencyMs,
    required this.packetLossPercent,
    required this.replies,
    required this.attempts,
  });
  final String host;
  final double? latencyMs;
  final double packetLossPercent;
  final int replies;
  final int attempts;
  bool get isStable => latencyMs != null && packetLossPercent < 5;
}
