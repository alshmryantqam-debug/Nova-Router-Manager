import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../../core/network/routeros_client.dart';
import '../../core/network/routeros_verified_client.dart';

class WireguardTunnelService {
  WireguardTunnelService(this.client);
  final RouterOsClient client;
  static const interfaceName = 'wg-remote-admin';
  static const listenPort = 13231;
  static const routerAddress = '10.200.200.1/24';
  static const clientAddress = '10.200.200.2/32';

  Future<WireguardTunnelResult> createOneClickTunnel() async {
    final current = await listInterfaces();
    if (current.any((r) => r['name'] == interfaceName)) {
      throw StateError('واجهة $interfaceName موجودة مسبقاً؛ لن أغيّر نفقاً قائماً تلقائياً.');
    }
    final cloudBefore = await client.command('/ip/cloud/print');
    final oldDdns = cloudBefore.isEmpty ? null : cloudBefore.first['ddns-enabled'];
    final id = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final prefix = 'NOVA:WG:$id';
    final keyPair = await X25519().newKeyPair();
    final privateData = await keyPair.extract();
    final publicData = await keyPair.extractPublicKey();
    final clientPrivate = base64Encode(privateData.bytes);
    final clientPublic = base64Encode(publicData.bytes);
    var interfaceAdded = false;
    var addressAdded = false;
    var peerAdded = false;
    var cloudTouched = false;
    try {
      await client.verifiedCommand('/interface/wireguard/add', args: <String,String>{
        'name': interfaceName, 'listen-port': '$listenPort', 'comment': '$prefix:interface',
      });
      interfaceAdded = true;
      final ifaces = await listInterfaces();
      final matches = ifaces.where((r) => r['name'] == interfaceName);
      final iface = matches.isEmpty ? <String,String>{} : matches.first;
      final routerPublic = (iface['public-key'] ?? '').trim();
      if (routerPublic.isEmpty) throw StateError('تعذر قراءة المفتاح العام للراوتر.');

      await client.verifiedCommand('/ip/address/add', args: <String,String>{
        'address': routerAddress, 'interface': interfaceName, 'comment': '$prefix:address',
      });
      addressAdded = true;
      await client.verifiedCommand('/ip/firewall/filter/add', args: <String,String>{
        'chain': 'input', 'protocol': 'udp', 'dst-port': '$listenPort',
        'action': 'accept', 'place-before': '0', 'comment': '$prefix:wan-port',
      });
      await client.verifiedCommand('/ip/firewall/filter/add', args: <String,String>{
        'chain': 'input', 'in-interface': interfaceName, 'src-address': clientAddress,
        'action': 'accept', 'place-before': '0', 'comment': '$prefix:peer-input',
      });
      await client.verifiedCommand('/interface/wireguard/peers/add', args: <String,String>{
        'interface': interfaceName, 'public-key': clientPublic,
        'allowed-address': clientAddress, 'comment': '$prefix:client',
      });
      peerAdded = true;
      await client.verifiedCommand('/ip/cloud/set', args: const <String,String>{'ddns-enabled':'yes'});
      cloudTouched = true;
      String? endpoint;
      for (var i=0; i<6; i++) {
        final rows = await client.command('/ip/cloud/print');
        if (rows.isNotEmpty) {
          endpoint = (rows.first['dns-name'] ?? '').trim();
          if (endpoint.isEmpty) endpoint = (rows.first['public-address'] ?? '').trim();
        }
        if (endpoint != null && endpoint.isNotEmpty) break;
        if (i < 5) await Future<void>.delayed(const Duration(seconds:1));
      }
      if (endpoint == null || endpoint.isEmpty) {
        throw StateError('لا يوجد DNS أو Public IP متاح. إذا كان الراوتر خلف CGNAT استخدم Back To Home VPN.');
      }
      final config = <String>[
        '[Interface]', 'PrivateKey = $clientPrivate', 'Address = $clientAddress', '',
        '[Peer]', 'PublicKey = $routerPublic', 'Endpoint = $endpoint:$listenPort',
        'AllowedIPs = 10.200.200.0/24', 'PersistentKeepalive = 25', '',
      ].join('\n');
      return WireguardTunnelResult(
        id:id, interfaceId:iface['.id'] ?? '', interfaceName:interfaceName,
        endpoint:endpoint, listenPort:listenPort, routerAddress:routerAddress,
        clientAddress:clientAddress, routerPublicKey:routerPublic,
        clientPublicKey:clientPublic, config:config, commentPrefix:prefix,
      );
    } catch (_) {
      await _rollback(prefix:prefix, clientPublic:clientPublic, interfaceAdded:interfaceAdded, addressAdded:addressAdded, peerAdded:peerAdded);
      if (cloudTouched && oldDdns != null) {
        try { await client.verifiedCommand('/ip/cloud/set', args: <String,String>{'ddns-enabled':oldDdns}); } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _rollback({required String prefix, required String clientPublic, required bool interfaceAdded, required bool addressAdded, required bool peerAdded}) async {
    try {
      if (peerAdded) {
        final peers = await listPeers();
        for (final row in peers.where((r) => r['public-key'] == clientPublic)) {
          final id = row['.id']; if (id != null) await client.verifiedCommand('/interface/wireguard/peers/remove', args: <String,String>{'.id':id});
        }
      }
      final rules = await client.command('/ip/firewall/filter/print');
      for (final row in rules.where((r) => (r['comment'] ?? '').startsWith('$prefix:'))) {
        final id = row['.id']; if (id != null) await client.verifiedCommand('/ip/firewall/filter/remove', args: <String,String>{'.id':id});
      }
      if (addressAdded) {
        final rows = await client.command('/ip/address/print');
        for (final row in rows.where((r) => r['comment'] == '$prefix:address')) {
          final id = row['.id']; if (id != null) await client.verifiedCommand('/ip/address/remove', args: <String,String>{'.id':id});
        }
      }
      if (interfaceAdded) {
        final rows = await listInterfaces();
        for (final row in rows.where((r) => r['comment'] == '$prefix:interface')) {
          final id = row['.id']; if (id != null) await client.verifiedCommand('/interface/wireguard/remove', args: <String,String>{'.id':id});
        }
      }
    } catch (_) {
      // Rollback is best-effort; preserve the original failure for the user.
    }
  }

  Future<BackToHomeResult> enableBackToHome() async {
    await client.verifiedCommand('/ip/cloud/set', args: const <String,String>{
      'ddns-enabled':'yes', 'back-to-home-vpn':'enabled',
    });
    for (var i=0; i<15; i++) {
      final rows = await client.command('/ip/cloud/print');
      if (rows.isNotEmpty) {
        final row=rows.first;
        final status=(row['vpn-status'] ?? '').trim();
        final config=(row['vpn-wireguard-client-config'] ?? '').trim();
        if (status == 'running' && config.isNotEmpty) {
          return BackToHomeResult(
            status:status, endpoint:(row['vpn-dns-name'] ?? '').trim(),
            port:int.tryParse(row['vpn-port'] ?? ''), config:config,
            warning:(row['warning'] ?? '').trim(),
          );
        }
        if (status == 'failed to connect') {
          throw StateError('تعذر الاتصال بخدمات MikroTik Cloud؛ تحقق من خروج UDP 15252 والوقت على الراوتر.');
        }
      }
      await Future<void>.delayed(const Duration(seconds:1));
    }
    throw StateError('Back To Home لم تصبح جاهزة؛ راجع /ip/cloud print وحاول مجدداً.');
  }

  Future<void> disableBackToHome() async { await client.verifiedCommand('/ip/cloud/set', args: const <String,String>{'back-to-home-vpn':'revoked-and-disabled'}); }
  Future<Map<String,String>> cloudStatus() async {
    final rows=await client.command('/ip/cloud/print');
    return rows.isEmpty ? <String,String>{} : rows.first;
  }
  Future<List<Map<String,String>>> listInterfaces() => client.command('/interface/wireguard/print');
  Future<List<Map<String,String>>> listPeers() => client.command('/interface/wireguard/peers/print');
  Future<void> setTunnelDisabled(String id, bool disabled) async { await client.verifiedCommand(disabled ? '/interface/wireguard/disable' : '/interface/wireguard/enable', args: <String,String>{'.id':id}); }
  Future<void> setPeerDisabled(String id, bool disabled) async { await client.verifiedCommand(disabled ? '/interface/wireguard/peers/disable' : '/interface/wireguard/peers/enable', args: <String,String>{'.id':id}); }
  Future<void> removePeer(String id) async { await client.verifiedCommand('/interface/wireguard/peers/remove', args: <String,String>{'.id':id}); }

  Future<void> removeTunnel(String id) async {
    final all=await listInterfaces();
    final found=all.where((r)=>r['.id']==id);
    if(found.isEmpty) return;
    final tunnel=found.first;
    if(tunnel['name']=='back-to-home-vpn') {
      await disableBackToHome();
      return;
    }
    final name=tunnel['name'] ?? '';
    final comment=tunnel['comment'] ?? '';
    final match=RegExp(r'^NOVA:WG:([^:]+):interface$').firstMatch(comment);
    final prefix=match==null ? null : 'NOVA:WG:${match.group(1)}:';
    final peers=await listPeers();
    for(final row in peers.where((r)=>r['interface']==name && r['dynamic']!='true')) {
      final peerId=row['.id']; if(peerId!=null) await removePeer(peerId);
    }
    final addresses=await client.command('/ip/address/print');
    for(final row in addresses.where((r)=>r['interface']==name)) {
      final rowId=row['.id']; if(rowId!=null) await client.verifiedCommand('/ip/address/remove',args:<String,String>{'.id':rowId});
    }
    final rules=await client.command('/ip/firewall/filter/print');
    for(final row in rules.where((r)=>(prefix!=null && (r['comment'] ?? '').startsWith(prefix)) || r['in-interface']==name || r['out-interface']==name)) {
      final rowId=row['.id']; if(rowId!=null) await client.verifiedCommand('/ip/firewall/filter/remove',args:<String,String>{'.id':rowId});
    }
    await client.verifiedCommand('/interface/wireguard/remove',args:<String,String>{'.id':id});
  }
}

class WireguardTunnelResult {
  const WireguardTunnelResult({required this.id,required this.interfaceId,required this.interfaceName,required this.endpoint,required this.listenPort,required this.routerAddress,required this.clientAddress,required this.routerPublicKey,required this.clientPublicKey,required this.config,required this.commentPrefix});
  final String id, interfaceId, interfaceName, endpoint, routerAddress, clientAddress, routerPublicKey, clientPublicKey, config, commentPrefix;
  final int listenPort;
}
class BackToHomeResult {
  const BackToHomeResult({required this.status,required this.endpoint,required this.port,required this.config,required this.warning});
  final String status, endpoint, config, warning;
  final int? port;
}
