import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/router_providers.dart';
import 'interfaces_service.dart';

const Color _interfaceBg = Color(0xFF080B12);
const Color _interfacePanel = Color(0xFF111722);
const Color _interfaceAccent = Color(0xFF8B7CFF);
const Color _interfaceMuted = Color(0xFF8D9AB0);

class InterfacesScreen extends ConsumerStatefulWidget {
  const InterfacesScreen({super.key});

  @override
  ConsumerState<InterfacesScreen> createState() => _InterfacesScreenState();
}

class _InterfacesScreenState extends ConsumerState<InterfacesScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  InterfacesService? _service;
  List<Map<String, String>> _interfaces = [];
  List<Map<String, String>> _vlans = [];
  List<Map<String, String>> _bridges = [];
  List<Map<String, String>> _bridgePorts = [];
  final Map<String, String> _rates = {};
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    final client = ref.read(activeRouterClientProvider);
    if (client != null) {
      _service = InterfacesService(client);
      _refresh();
    } else {
      _loading = false;
      _error = 'لا يوجد راوتر متصل. ارجع واختر الراوتر أولاً.';
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final service = _service;
    if (service == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final values = await Future.wait([
        service.getInterfaces(), service.getVlans(), service.getBridges(), service.getBridgePorts(),
      ]);
      final rates = <String, String>{};
      await Future.wait(values[0].where((row) {
        final type = (row['type'] ?? '').toLowerCase();
        return (row['name'] ?? '').isNotEmpty && (type.contains('ether') || type.contains('sfp'));
      }).map((row) async {
        final name = row['name']!;
        try {
          final monitor = await service.monitorEthernet(name);
          final rate = monitor['rate'];
          if (rate != null && rate.isNotEmpty) rates[name] = rate;
        } catch (_) {
          // Some virtual interfaces and unsupported ports do not expose Ethernet monitor data.
        }
      }));
      if (!mounted) return;
      setState(() {
        _interfaces = values[0]; _vlans = values[1]; _bridges = values[2]; _bridgePorts = values[3];
        _rates
          ..clear()
          ..addAll(rates);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = _friendly(e); });
    }
  }

  String _friendly(Object e) => e.toString().replaceFirst('Exception: ', '').replaceFirst('Bad state: ', '');

  Future<void> _run(String key, Future<void> Function() action, {String success = 'تم تنفيذ العملية'}) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
      await _refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_friendly(e)), backgroundColor: const Color(0xFF9D3348),
      ));
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<String?> _ask(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
      backgroundColor: _interfacePanel,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      content: TextField(controller: controller, autofocus: true, style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(enabledBorder: UnderlineInputBorder(), focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: _interfaceAccent)))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('حفظ')),
      ],
    ));
    controller.dispose();
    return value;
  }

  Future<void> _editInterface(Map<String, String> row, {required bool comment}) async {
    final id = row['.id'] ?? '';
    final value = await _ask(comment ? 'تعديل ملاحظة المنفذ' : 'تغيير اسم المنفذ',
      row[comment ? 'comment' : 'name'] ?? '');
    if (value == null || value.trim().isEmpty && !comment) return;
    final service = _service;
    if (service == null) return;
    await _run('edit:$id', () => comment
      ? service.setInterfaceComment(id, value)
      : service.renameInterface(id, value), success: 'تم تحديث بيانات المنفذ');
  }

  Future<void> _inspectSfp(Map<String, String> row) async {
    final service = _service;
    if (service == null) return;
    final name = row['name'] ?? '';
    try {
      final data = await service.monitorEthernet(name);
      if (!mounted) return;
      final fields = <List<String>>[
        ['الحالة', data['status'] ?? '—'], ['سرعة الربط', data['rate'] ?? 'غير متاحة'],
        ['حرارة وحدة SFP', data['sfp-temperature'] ?? 'غير مدعومة'],
        ['استقبال RX', data['sfp-rx-power'] ?? 'غير مدعوم'],
        ['إرسال TX', data['sfp-tx-power'] ?? 'غير مدعوم'],
        ['فقد الإشارة RX', data['sfp-rx-loss'] ?? '—'], ['عطل الإرسال TX', data['sfp-tx-fault'] ?? '—'],
        ['الوحدة موجودة', data['sfp-module-present'] ?? '—'], ['نوع الوحدة', data['sfp-type'] ?? '—'],
        ['الشركة/الموديل', '${data['sfp-vendor-name'] ?? '—'} / ${data['sfp-vendor-part-number'] ?? '—'}'],
      ];
      await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
        backgroundColor: _interfacePanel,
        title: Text('فحص العدسة واللينك • $name', style: const TextStyle(color: Colors.white, fontSize: 17)),
        content: SizedBox(width: double.maxFinite, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
          children: fields.map((f) => ListTile(dense: true, contentPadding: EdgeInsets.zero,
            title: Text(f[0], style: const TextStyle(color: _interfaceMuted, fontSize: 12)),
            subtitle: Text(f[1], style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)))).toList()))),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إغلاق'))],
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر فحص $name: ${_friendly(e)}')));
    }
  }

  Future<void> _addVlan() async {
    final nameC = TextEditingController(text: 'vlan-new');
    final idC = TextEditingController(text: '10');
    String? parent = _interfaces.isEmpty ? null : _interfaces.first['name'];
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<Map<String, String>>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        backgroundColor: _interfacePanel,
        title: const Text('إضافة VLAN', style: TextStyle(color: Colors.white)),
        content: Form(key: formKey, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(controller: nameC, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'اسم VLAN'),
            validator: (v) => (v == null || v.trim().isEmpty) ? 'الاسم مطلوب' : null),
          TextFormField(controller: idC, keyboardType: TextInputType.number, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'VLAN ID (1–4094)'),
            validator: (v) { final n = int.tryParse(v ?? ''); return n == null || n < 1 || n > 4094 ? 'أدخل رقماً من 1 إلى 4094' : null; }),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: parent, dropdownColor: _interfacePanel, decoration: const InputDecoration(labelText: 'المنفذ الأب'),
            items: _interfaces.map((r) => DropdownMenuItem(value: r['name'], child: Text(r['name'] ?? '—'))).toList(),
            onChanged: (v) => setDialogState(() => parent = v), validator: (v) => v == null ? 'اختر المنفذ الأب' : null),
        ]))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () {
            if (formKey.currentState?.validate() != true || parent == null) return;
            Navigator.pop(dialogContext, {'name': nameC.text.trim(), 'id': idC.text.trim(), 'parent': parent!});
          }, child: const Text('إنشاء')),
        ],
      ),
    ));
    nameC.dispose(); idC.dispose();
    if (result == null || _service == null) return;
    await _run('add-vlan', () => _service!.createVlan(name: result['name']!, vlanId: int.parse(result['id']!), interfaceName: result['parent']!), success: 'تم إنشاء VLAN');
  }

  Future<void> _bridgePortOptions(Map<String, String> row) async {
    final service = _service;
    if (service == null) return;
    final id = row['.id'] ?? '';
    final currentBridge = row['bridge'] ?? '';
    String? bridge = _bridges.any((b) => b['name'] == currentBridge) ? currentBridge : (_bridges.isEmpty ? null : _bridges.first['name']);
    final horizonC = TextEditingController(text: row['horizon'] ?? '');
    final result = await showDialog<Map<String, String>>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        backgroundColor: _interfacePanel,
        title: Text('إدارة منفذ ${row['interface'] ?? ''}', style: const TextStyle(color: Colors.white)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(value: bridge, dropdownColor: _interfacePanel, decoration: const InputDecoration(labelText: 'نقل إلى بريدج'),
            items: _bridges.map((b) => DropdownMenuItem(value: b['name'], child: Text(b['name'] ?? '—'))).toList(),
            onChanged: (v) => setDialogState(() => bridge = v)),
          TextField(controller: horizonC, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Horizon (فارغ لإلغاء العزل)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: bridge == null ? null : () => Navigator.pop(dialogContext, {'bridge': bridge!, 'horizon': horizonC.text.trim()}), child: const Text('حفظ')),
        ],
      ),
    ));
    horizonC.dispose();
    if (result == null) return;
    await _run('bridge:$id', () => service.moveBridgePort(portId: id, bridgeName: result['bridge']!, horizon: result['horizon']), success: 'تم تحديث منفذ البريدج');
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null || !identical(client, _service == null ? null : ref.read(activeRouterClientProvider))) {
      if (client == null) return const Scaffold(backgroundColor: _interfaceBg, body: Center(child: Text('اتصل بالراوتر أولاً', style: TextStyle(color: Colors.white))));
    }
    return Scaffold(
      backgroundColor: _interfaceBg,
      appBar: AppBar(backgroundColor: _interfaceBg, foregroundColor: Colors.white, title: const Text('المنافذ والفايبر و VLAN'),
        actions: [IconButton(onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh_rounded))],
        bottom: TabBar(controller: _tabs, isScrollable: true, indicatorColor: _interfaceAccent, labelColor: Colors.white, unselectedLabelColor: _interfaceMuted,
          tabs: const [Tab(icon: Icon(Icons.settings_ethernet), text: 'المنافذ والفايبر'), Tab(icon: Icon(Icons.lan), text: 'VLAN'), Tab(icon: Icon(Icons.hub), text: 'Bridges')])),
      body: _loading ? const Center(child: CircularProgressIndicator(color: _interfaceAccent)) : _error != null
        ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, color: _interfaceMuted, size: 40), const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
            const SizedBox(height: 12), FilledButton.icon(onPressed: _refresh, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
          ])))
        : TabBarView(controller: _tabs, children: [_portsTab(), _vlanTab(), _bridgesTab()]),
    );
  }

  Widget _portsTab() => RefreshIndicator(color: _interfaceAccent, onRefresh: _refresh, child: ListView(
    padding: const EdgeInsets.all(12), children: [
      _sectionHeader('بطاقات الشبكة والفايبر', '${_interfaces.length} منفذ • قراءات مباشرة من الراوتر'),
      if (_interfaces.isEmpty) const _EmptyInterfaces('لا توجد منافذ لعرضها'),
      ..._interfaces.map((row) {
        final name = row['name'] ?? '—'; final id = row['.id'] ?? '';
        final disabled = row['disabled'] == 'true'; final running = row['running'] == 'true'; final slave = row['slave'] == 'true';
        final state = disabled ? 'Disabled' : slave ? 'Slave' : running ? 'Running' : 'Down';
        return Card(color: _interfacePanel, child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Icon(Icons.cable, color: _interfaceAccent), const SizedBox(width: 8), Expanded(child: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
            _stateChip(state, disabled ? Colors.redAccent : running ? Colors.greenAccent : _interfaceMuted)]),
          const SizedBox(height: 8),
          Text('${row['type'] ?? 'interface'} • Link: ${_rates[name] ?? 'غير متاح'} • RX error: ${row['rx-error'] ?? '—'} • TX drop: ${row['tx-drop'] ?? '—'}',
            style: const TextStyle(color: _interfaceMuted, fontSize: 11)),
          if ((row['comment'] ?? '').isNotEmpty) Text(row['comment']!, style: const TextStyle(color: _interfaceMuted, fontSize: 11)),
          Wrap(spacing: 2, runSpacing: 2, children: [
            TextButton.icon(onPressed: () => _run('toggle:$id', () => _service!.setEnabled(id, enabled: disabled), success: disabled ? 'تم تفعيل المنفذ' : 'تم تعطيل المنفذ'),
              icon: Icon(disabled ? Icons.play_arrow : Icons.pause), label: Text(disabled ? 'تفعيل' : 'تعطيل')),
            TextButton.icon(onPressed: () => _editInterface(row, comment: false), icon: const Icon(Icons.drive_file_rename_outline), label: const Text('الاسم')),
            TextButton.icon(onPressed: () => _editInterface(row, comment: true), icon: const Icon(Icons.notes), label: const Text('ملاحظة')),
            TextButton.icon(onPressed: () => _inspectSfp(row), icon: const Icon(Icons.troubleshoot), label: const Text('فحص العدسة/اللينك')),
          ]),
        ])));
      }),
    ]));

  Widget _vlanTab() => RefreshIndicator(color: _interfaceAccent, onRefresh: _refresh, child: ListView(padding: const EdgeInsets.all(12), children: [
    Row(children: [Expanded(child: _sectionHeader('شبكات VLAN الحالية', '${_vlans.length} شبكة')), FilledButton.icon(onPressed: _addVlan, icon: const Icon(Icons.add), label: const Text('إضافة'))]),
    if (_vlans.isEmpty) const _EmptyInterfaces('لا توجد VLANs معرفة حالياً'),
    ..._vlans.map((v) => Card(color: _interfacePanel, child: ListTile(
      leading: const Icon(Icons.lan, color: _interfaceAccent), title: Text(v['name'] ?? '—', style: const TextStyle(color: Colors.white)),
      subtitle: Text('VLAN ID: ${v['vlan-id'] ?? '—'} • Parent: ${v['interface'] ?? '—'}${v['disabled'] == 'true' ? ' • Disabled' : ''}',
        style: const TextStyle(color: _interfaceMuted, fontSize: 12))))),
  ]));

  Widget _bridgesTab() => RefreshIndicator(color: _interfaceAccent, onRefresh: _refresh, child: ListView(padding: const EdgeInsets.all(12), children: [
    _sectionHeader('Bridges & Ports', '${_bridges.length} بريدج • ${_bridgePorts.length} منفذ مرتبط'),
    if (_bridges.isEmpty) const _EmptyInterfaces('لا توجد Bridges معرفة حالياً'),
    ..._bridges.map((bridge) {
      final name = bridge['name'] ?? '—';
      final ports = _bridgePorts.where((p) => p['bridge'] == name).toList();
      return Card(color: _interfacePanel, child: ExpansionTile(
        iconColor: _interfaceAccent, collapsedIconColor: _interfaceMuted,
        leading: const Icon(Icons.hub, color: _interfaceAccent), title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        subtitle: Text('${ports.length} منفذ', style: const TextStyle(color: _interfaceMuted)),
        children: ports.isEmpty ? [const ListTile(title: Text('لا توجد منافذ مرتبطة', style: TextStyle(color: _interfaceMuted)))] : ports.map((p) => ListTile(
          leading: const Icon(Icons.cable, color: _interfaceMuted), title: Text(p['interface'] ?? '—', style: const TextStyle(color: Colors.white)),
          subtitle: Text('Horizon: ${(p['horizon'] ?? '').isEmpty ? 'غير معزول' : p['horizon']!}${p['disabled'] == 'true' ? ' • Disabled' : ''}',
            style: const TextStyle(color: _interfaceMuted, fontSize: 11)),
          trailing: IconButton(tooltip: 'نقل المنفذ أو تغيير العزل', onPressed: () => _bridgePortOptions(p), icon: const Icon(Icons.tune, color: _interfaceAccent)),
        )).toList(),
      ));
    }),
  ]));

  Widget _sectionHeader(String title, String subtitle) => Padding(padding: const EdgeInsets.fromLTRB(4, 8, 4, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
    const SizedBox(height: 3), Text(subtitle, style: const TextStyle(color: _interfaceMuted, fontSize: 11)),
  ]));

  Widget _stateChip(String text, Color color) => Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(color: color.withOpacity(.13), borderRadius: BorderRadius.circular(20), border: Border.all(color: color.withOpacity(.4))),
    child: Text(text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800)));

}

class _EmptyInterfaces extends StatelessWidget {
  const _EmptyInterfaces(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(22), child: Center(child: Text(message, style: const TextStyle(color: _interfaceMuted))));
}
