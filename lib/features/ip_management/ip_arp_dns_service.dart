import '../../core/network/routeros_client.dart';

/// RouterOS IP address, ARP, pool and DNS operations.
/// Methods call the live RouterOS API; they do not return fabricated records.
class IpArpDnsService {
  IpArpDnsService(this.client);
  final RouterOsClient client;

  Future<List<Map<String, String>>> listAddresses() =>
      client.command('/ip/address/print');

  Future<void> addAddress({
    required String address,
    required String interface,
    String network = '',
    String comment = '',
    bool disabled = false,
  }) async {
    _required(address, 'address');
    _required(interface, 'interface');
    final args = <String, String>{'address': address.trim(), 'interface': interface.trim()};
    if (network.trim().isNotEmpty) args['network'] = network.trim();
    if (comment.trim().isNotEmpty) args['comment'] = comment.trim();
    if (disabled) args['disabled'] = 'yes';
    await client.command('/ip/address/add', args: args);
  }

  Future<void> setAddressDisabled(String id, bool disabled) async =>
      client.command(disabled ? '/ip/address/disable' : '/ip/address/enable', args: {'.id': _required(id, '.id')});

  Future<void> updateAddress(String id, {String? address, String? interface, String? comment}) async {
    final args = <String, String>{'.id': _required(id, '.id')};
    if (address != null) args['address'] = address.trim();
    if (interface != null) args['interface'] = interface.trim();
    if (comment != null) args['comment'] = comment.trim();
    if (args.length == 1) return;
    await client.command('/ip/address/set', args: args);
  }

  Future<void> removeAddress(String id) async =>
      client.command('/ip/address/remove', args: {'.id': _required(id, '.id')});

  Future<List<Map<String, String>>> listArp() => client.command('/ip/arp/print');

  Future<void> makeArpStatic(String id) async =>
      client.command('/ip/arp/make-static', args: {'.id': _required(id, '.id')});

  Future<void> removeArp(String id) async =>
      client.command('/ip/arp/remove', args: {'.id': _required(id, '.id')});

  Future<List<Map<String, String>>> listPools() => client.command('/ip/pool/print');

  Future<void> addPool({required String name, required String ranges, String comment = ''}) async {
    _required(name, 'name');
    _required(ranges, 'ranges');
    final args = <String, String>{'name': name.trim(), 'ranges': ranges.trim()};
    if (comment.trim().isNotEmpty) args['comment'] = comment.trim();
    await client.command('/ip/pool/add', args: args);
  }

  Future<void> updatePool(String id, {String? name, String? ranges, String? comment}) async {
    final args = <String, String>{'.id': _required(id, '.id')};
    if (name != null) args['name'] = name.trim();
    if (ranges != null) args['ranges'] = ranges.trim();
    if (comment != null) args['comment'] = comment.trim();
    if (args.length > 1) await client.command('/ip/pool/set', args: args);
  }

  Future<void> removePool(String id) async =>
      client.command('/ip/pool/remove', args: {'.id': _required(id, '.id')});

  Future<List<Map<String, String>>> listDnsSettings() => client.command('/ip/dns/print');

  Future<void> setDnsServers(String servers) async {
    final value = _required(servers, 'servers');
    await client.command('/ip/dns/set', args: {'servers': value});
  }

  Future<List<Map<String, String>>> listDnsStatic() => client.command('/ip/dns/static/print');

  Future<void> addDnsStatic({required String name, String? address, String? type, String? comment}) async {
    final host = _required(name, 'name');
    final args = <String, String>{'name': host};
    if (address != null && address.trim().isNotEmpty) args['address'] = address.trim();
    if (type != null && type.trim().isNotEmpty) args['type'] = type.trim();
    if (comment != null && comment.trim().isNotEmpty) args['comment'] = comment.trim();
    await client.command('/ip/dns/static/add', args: args);
  }

  Future<void> removeDnsStatic(String id) async =>
      client.command('/ip/dns/static/remove', args: {'.id': _required(id, '.id')});

  Future<void> flushDnsCache() async => client.command('/ip/dns/cache/flush');

  String _required(String value, String field) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(value, field, 'القيمة مطلوبة');
    return trimmed;
  }
}
