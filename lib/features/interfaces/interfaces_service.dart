import '../../core/network/routeros_client.dart';

/// Live interface, SFP diagnostics, VLAN and bridge operations for RouterOS.
class InterfacesService {
  const InterfacesService(this._client);

  final RouterOsClient _client;

  Future<List<Map<String, String>>> getInterfaces() => _client.command(
        '/interface/print',
        args: const <String, String>{
          '.proplist': '.id,name,type,comment,disabled,running,slave,rx-error,tx-drop,mac-address,mtu',
        },
      );

  Future<void> setEnabled(String id, {required bool enabled}) async {
    if (id.trim().isEmpty) throw ArgumentError('معرّف المنفذ غير صالح');
    await _client.command(enabled ? '/interface/enable' : '/interface/disable',
        args: <String, String>{'numbers': id});
  }

  Future<void> renameInterface(String id, String name) async {
    final value = name.trim();
    if (id.trim().isEmpty || value.isEmpty) throw ArgumentError('أدخل اسم المنفذ');
    await _client.command('/interface/set',
        args: <String, String>{'.id': id, 'name': value});
  }

  Future<void> setInterfaceComment(String id, String comment) async {
    if (id.trim().isEmpty) throw ArgumentError('معرّف المنفذ غير صالح');
    await _client.command('/interface/set',
        args: <String, String>{'.id': id, 'comment': comment.trim()});
  }

  /// Runs a one-shot monitor request; continuous monitor is not supported by RouterOS REST/API.
  Future<Map<String, String>> monitorEthernet(String interfaceName) async {
    final name = interfaceName.trim();
    if (name.isEmpty) throw ArgumentError('اختر منفذاً أولاً');
    final rows = await _client.command('/interface/ethernet/monitor',
        args: <String, String>{'numbers': name, 'once': ''});
    if (rows.isEmpty) throw StateError('لم يرجع الراوتر قراءات لهذا المنفذ');
    return Map<String, String>.unmodifiable(rows.first);
  }

  Future<List<Map<String, String>>> getVlans() => _client.command(
        '/interface/vlan/print',
        args: const <String, String>{'.proplist': '.id,name,vlan-id,interface,disabled,running,comment'},
      );

  Future<void> createVlan({
    required String name,
    required int vlanId,
    required String interfaceName,
    String comment = '',
  }) async {
    final safeName = name.trim();
    final parent = interfaceName.trim();
    if (safeName.isEmpty || parent.isEmpty) throw ArgumentError('أدخل اسم VLAN والمنفذ الأب');
    if (vlanId < 1 || vlanId > 4094) throw ArgumentError.value(vlanId, 'vlanId', 'VLAN ID يجب أن يكون بين 1 و4094');
    await _client.command('/interface/vlan/add', args: <String, String>{
      'name': safeName,
      'vlan-id': '$vlanId',
      'interface': parent,
      if (comment.trim().isNotEmpty) 'comment': comment.trim(),
    });
  }

  Future<List<Map<String, String>>> getBridges() => _client.command(
        '/interface/bridge/print',
        args: const <String, String>{'.proplist': '.id,name,comment,disabled,running'},
      );

  Future<List<Map<String, String>>> getBridgePorts() => _client.command(
        '/interface/bridge/port/print',
        args: const <String, String>{'.proplist': '.id,interface,bridge,horizon,disabled,hw,role'},
      );

  Future<void> moveBridgePort({
    required String portId,
    required String bridgeName,
    String? horizon,
  }) async {
    if (portId.trim().isEmpty || bridgeName.trim().isEmpty) {
      throw ArgumentError('اختر المنفذ والبريدج');
    }
    await _client.command('/interface/bridge/port/set', args: <String, String>{
      '.id': portId,
      'bridge': bridgeName.trim(),
      'horizon': (horizon ?? '').trim(),
    });
  }

  Future<void> setBridgePortIsolated(String portId, {required bool isolated}) async {
    if (portId.trim().isEmpty) throw ArgumentError('معرّف منفذ البريدج غير صالح');
    await _client.command('/interface/bridge/port/set', args: <String, String>{
      '.id': portId,
      'horizon': isolated ? '1' : 'none',
    });
  }
}
