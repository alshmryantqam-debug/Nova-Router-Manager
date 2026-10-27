import 'dart:async';

import '../../core/network/routeros_client.dart';

/// Configures a router-side overlay network or a persistent outbound VPN client.
///
/// ZeroTier requires the RouterOS ZeroTier package to be installed and the
/// device to be authorized in the ZeroTier Central network when it is private.
/// The service deliberately opens router INPUT only on its ZeroTier interface;
/// it does not expose the router's management ports to the public WAN.
class CgnatBypassService {
  CgnatBypassService(this.client);

  final RouterOsClient client;

  static const String zeroTierName = 'nova-zerotier';
  static const String zeroTierInstance = 'zt1';
  static const String commentPrefix = 'NOVA:CGNAT';
  static const String reverseNamePrefix = 'nova-reverse';

  Future<ZeroTierTunnelStatus> connectZeroTier(String networkId) async {
    final id = networkId.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(id)) {
      throw const FormatException('Network ID يجب أن يتكون من 16 خانة hexadecimal.');
    }

    final instanceRows = await client.command('/zerotier/print');
    if (instanceRows.isEmpty) {
      throw StateError(
        'لم يعثر RouterOS على ZeroTier. ثبّت حزمة ZeroTier المتوافقة مع إصدار RouterOS والمعمارية ثم أعد المحاولة.',
      );
    }

    // The instance must be enabled before its network interface can establish.
    try {
      await client.command('/zerotier/enable', args: const <String, String>{'numbers': zeroTierInstance});
    } catch (_) {
      // Some RouterOS builds expose the default instance already enabled.
    }

    final current = await listZeroTierInterfaces();
    final existing = current.where((row) => (row['network'] ?? '').toLowerCase() == id);
    String iface;
    if (existing.isNotEmpty) {
      iface = (existing.first['name'] ?? '').trim();
      if (iface.isEmpty) iface = zeroTierName;
      final existingId = existing.first['.id'];
      if (existingId != null) {
        await client.command('/zerotier/interface/set', args: <String, String>{
          '.id': existingId,
          'allow-managed': 'yes',
          'allow-global': 'yes',
          'disabled': 'no',
        });
      }
    } else {
      iface = _uniqueInterfaceName(current.map((r) => r['name'] ?? '').toSet());
      await client.command('/zerotier/interface/add', args: <String, String>{
        'name': iface,
        'network': id,
        'instance': zeroTierInstance,
        'allow-managed': 'yes',
        'allow-global': 'yes',
        'disabled': 'no',
        'comment': '$commentPrefix:ZT:$id',
      });
    }

    // Avoid duplicating app-owned rules on subsequent presses.
    final filters = await client.command('/ip/firewall/filter/print');
    final ruleComment = '$commentPrefix:ZT:$id:input';
    if (!filters.any((r) => r['comment'] == ruleComment)) {
      await client.command('/ip/firewall/filter/add', args: <String, String>{
        'chain': 'input',
        'action': 'accept',
        'in-interface': iface,
        'place-before': '0',
        'comment': ruleComment,
      });
    }

    return pollZeroTierStatus(networkId: id, interfaceName: iface);
  }

  Future<ZeroTierTunnelStatus> pollZeroTierStatus({
    required String networkId,
    String? interfaceName,
  }) async {
    final wantedName = interfaceName;
    List<Map<String, String>> interfaceRows = <Map<String, String>>[];
    List<Map<String, String>> addressRows = <Map<String, String>>[];
    for (var attempt = 0; attempt < 8; attempt++) {
      interfaceRows = await listZeroTierInterfaces();
      final matches = interfaceRows.where((row) =>
          (wantedName == null || row['name'] == wantedName) &&
          (row['network'] ?? '').toLowerCase() == networkId.toLowerCase());
      if (matches.isNotEmpty) {
        final row = matches.first;
        final name = (row['name'] ?? '').trim();
        addressRows = await client.command('/ip/address/print');
        final assigned = addressRows
            .where((r) => r['interface'] == name)
            .map((r) => (r['address'] ?? '').split('/').first.trim())
            .where((address) => address.isNotEmpty && !address.startsWith('0.0.0.0'))
            .toList(growable: false);
        final status = (row['status'] ?? (row['running'] == 'true' ? 'OK' : 'REQUESTING_CONFIGURATION')).trim();
        if (status.toUpperCase() == 'OK' && assigned.isNotEmpty) {
          return ZeroTierTunnelStatus(
            networkId: networkId,
            interfaceName: name,
            status: status,
            ipAddress: assigned.first,
            authorized: true,
            message: 'اتصل ZeroTier. تأكد من اعتماد عضو الراوتر من ZeroTier Central للشبكات الخاصة.',
          );
        }
        if (attempt == 7) {
          return ZeroTierTunnelStatus(
            networkId: networkId,
            interfaceName: name,
            status: status.isEmpty ? 'connecting' : status,
            ipAddress: assigned.isEmpty ? null : assigned.first,
            authorized: status.toUpperCase() == 'OK',
            message: status.toUpperCase() == 'OK'
                ? 'الاتصال قائم لكن لم يظهر عنوان IP مُدار بعد.'
                : 'النفق ينتظر اعتماد العضو أو اتصال ZeroTier. تحقق من ZeroTier Central وحزمة RouterOS.',
          );
        }
      }
      if (attempt < 7) await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw StateError('لم تظهر واجهة ZeroTier بعد الإنشاء؛ تحقق من الحزمة وسجلات /zerotier.');
  }

  Future<List<Map<String, String>>> listZeroTierInterfaces() =>
      client.command('/zerotier/interface/print');

  Future<List<Map<String, String>>> listZeroTierAddresses() async {
    final interfaces = await listZeroTierInterfaces();
    final names = interfaces.map((r) => r['name']).whereType<String>().toSet();
    final addresses = await client.command('/ip/address/print');
    return addresses.where((row) => names.contains(row['interface'])).toList(growable: false);
  }

  Future<ReverseVpnResult> createReverseVpn({
    required String type,
    required String server,
    required String username,
    required String password,
    String? ipsecSecret,
    int? port,
  }) async {
    final normalizedType = type.toUpperCase();
    if (!const <String>{'L2TP', 'SSTP', 'OVPN'}.contains(normalizedType)) {
      throw ArgumentError.value(type, 'type', 'نوع النفق غير مدعوم.');
    }
    if (server.trim().isEmpty || username.trim().isEmpty || password.isEmpty) {
      throw const FormatException('أدخل عنوان السيرفر واسم المستخدم وكلمة المرور.');
    }
    if (port != null && (port < 1 || port > 65535)) {
      throw const FormatException('منفذ VPN غير صالح.');
    }

    final path = _vpnPath(normalizedType);
    final name = _vpnInterfaceName(normalizedType);
    final schedulerName = '$name-watchdog';
    final current = await client.command('$path/print');
    if (current.any((row) => row['name'] == name)) {
      throw StateError('واجهة $name موجودة مسبقًا؛ لن أستبدل اتصالًا قائمًا تلقائيًا.');
    }

    final args = <String, String>{
      'name': name,
      'connect-to': server.trim(),
      'user': username.trim(),
      'password': password,
      'dial-on-demand': 'no',
      'add-default-route': 'no',
      'disabled': 'no',
      'comment': '$commentPrefix:REVERSE:$normalizedType',
    };
    if (normalizedType == 'SSTP') {
      args['verify-server-certificate'] = 'yes';
      if (port != null) args['port'] = '$port';
    } else if (normalizedType == 'L2TP') {
      // Prefer encrypted L2TP/IPsec when the operator provides a PSK.
      if (ipsecSecret != null && ipsecSecret.isNotEmpty) {
        args['use-ipsec'] = 'yes';
        args['ipsec-secret'] = ipsecSecret;
      } else {
        args['use-ipsec'] = 'no';
      }
    } else {
      if (port != null) args['port'] = '$port';
      args['protocol'] = 'tcp';
      args['certificate'] = 'none';
      args['verify-server-certificate'] = 'yes';
    }

    await client.command('$path/add', args: args);
    try {
      final schedulerScript = _watchdogScript(normalizedType, name);
      await client.command('/system/scheduler/add', args: <String, String>{
        'name': schedulerName,
        'interval': '1m',
        'start-time': 'startup',
        'on-event': schedulerScript,
        'policy': 'read,write,test',
        'disabled': 'no',
        'comment': '$commentPrefix:WATCHDOG:$name',
      });
    } catch (_) {
      // Do not leave a client without its requested recovery mechanism.
      final created = await client.command('$path/print');
      for (final row in created.where((r) => r['name'] == name)) {
        final id = row['.id'];
        if (id != null) {
          try { await client.command('$path/remove', args: <String, String>{'.id': id}); } catch (_) {}
        }
      }
      rethrow;
    }
    return pollReverseVpn(type: normalizedType, name: name);
  }

  Future<ReverseVpnResult> pollReverseVpn({
    required String type,
    required String name,
  }) async {
    final path = _vpnPath(type.toUpperCase());
    final rows = await client.command('$path/print');
    final match = rows.where((row) => row['name'] == name);
    if (match.isEmpty) {
      return ReverseVpnResult(
        type: type.toUpperCase(),
        name: name,
        state: 'missing',
        remoteAddress: null,
        localAddress: null,
      );
    }
    final row = match.first;
    final state = row['running'] == 'true' || row['status'] == 'connected'
        ? 'connected'
        : (row['disabled'] == 'true' || row['disabled'] == 'yes' ? 'disabled' : 'connecting');
    return ReverseVpnResult(
      type: type.toUpperCase(),
      name: name,
      state: state,
      remoteAddress: _firstAddress(row, const <String>['remote-address', 'remote-address6']),
      localAddress: _firstAddress(row, const <String>['local-address', 'local-address6']),
    );
  }

  Future<List<ReverseVpnResult>> listReverseVpns() async {
    final results = <ReverseVpnResult>[];
    for (final type in const <String>['L2TP', 'SSTP', 'OVPN']) {
      final rows = await client.command('${_vpnPath(type)}/print');
      for (final row in rows.where((r) => (r['comment'] ?? '').startsWith('$commentPrefix:REVERSE:'))) {
        results.add(await pollReverseVpn(type: type, name: row['name'] ?? ''));
      }
    }
    return results;
  }

  Future<void> removeReverseVpn(ReverseVpnResult tunnel) async {
    final path = _vpnPath(tunnel.type);
    final schedulers = await client.command('/system/scheduler/print');
    for (final row in schedulers.where((r) => r['name'] == '${tunnel.name}-watchdog')) {
      final id = row['.id'];
      if (id != null) await client.command('/system/scheduler/remove', args: <String, String>{'.id': id});
    }
    final rows = await client.command('$path/print');
    for (final row in rows.where((r) => r['name'] == tunnel.name && (r['comment'] ?? '').startsWith('$commentPrefix:REVERSE:'))) {
      final id = row['.id'];
      if (id != null) await client.command('$path/remove', args: <String, String>{'.id': id});
    }
  }

  String _watchdogScript(String type, String name) {
    final path = _vpnPath(type);
    final safeName = name.replaceAll('"', r'\\"');
    return ':local t [' + path + ' find where name="' + safeName + '"]; '
        ':if ([:len \$t] > 0) do={ '
        ':if ([' + path + ' get \$t running] = false) do={ '
        + path + ' disable \$t; :delay 2s; ' + path + ' enable \$t; '
        '} }';
  }
  String _vpnPath(String type) {
    switch (type.toUpperCase()) {
      case 'L2TP': return '/interface/l2tp-client';
      case 'SSTP': return '/interface/sstp-client';
      case 'OVPN': return '/interface/ovpn-client';
      default: throw ArgumentError.value(type, 'type', 'نوع VPN غير مدعوم.');
    }
  }

  String _vpnInterfaceName(String type) => '$reverseNamePrefix-${type.toLowerCase()}';

  String _uniqueInterfaceName(Set<String> existing) {
    if (!existing.contains(zeroTierName)) return zeroTierName;
    for (var i = 2; i < 100; i++) {
      final candidate = '$zeroTierName-$i';
      if (!existing.contains(candidate)) return candidate;
    }
    throw StateError('تعذر اختيار اسم واجهة ZeroTier فريد.');
  }

  String? _firstAddress(Map<String, String> row, List<String> keys) {
    for (final key in keys) {
      final value = (row[key] ?? '').trim();
      if (value.isNotEmpty && value != '0.0.0.0') return value;
    }
    return null;
  }
}

class ZeroTierTunnelStatus {
  const ZeroTierTunnelStatus({
    required this.networkId,
    required this.interfaceName,
    required this.status,
    required this.ipAddress,
    required this.authorized,
    required this.message,
  });

  final String networkId;
  final String interfaceName;
  final String status;
  final String? ipAddress;
  final bool authorized;
  final String message;
}

class ReverseVpnResult {
  const ReverseVpnResult({
    required this.type,
    required this.name,
    required this.state,
    required this.remoteAddress,
    required this.localAddress,
  });

  final String type;
  final String name;
  final String state;
  final String? remoteAddress;
  final String? localAddress;
}
