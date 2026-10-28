import '../../core/network/routeros_verified_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _natBg = Color(0xFF080B12);
const Color _natPanel = Color(0xFF111722);
const Color _natMuted = Color(0xFF8D9AB0);
const Color _natAccent = Color(0xFF8B7CFF);
const Color _natGreen = Color(0xFF43D9A3);
const Color _natRed = Color(0xFFFF657A);

class NatAddressListScreen extends ConsumerStatefulWidget {
  const NatAddressListScreen({super.key});
  @override
  ConsumerState<NatAddressListScreen> createState() => _NatAddressListScreenState();
}

class _NatAddressListScreenState extends ConsumerState<NatAddressListScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  RouterOsClient? _client;
  List<Map<String, String>> _nat = <Map<String, String>>[];
  List<Map<String, String>> _addresses = <Map<String, String>>[];
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String _listFilter = 'الكل';
  String _search = '';

  @override
  void initState() {
    super.initState();
    _client = ref.read(activeRouterClientProvider);
    if (_client == null) {
      _loading = false;
      _error = 'اتصل بالراوتر أولاً.';
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String _friendly(Object error) => error.toString().replaceFirst('RouterOsException: ', '').replaceFirst('Exception: ', '');
  bool _truth(String? value) => value == 'true' || value == 'yes';

  Future<void> _load() async {
    final client = ref.read(activeRouterClientProvider);
    if (client == null) {
      if (mounted) setState(() { _loading = false; _error = 'اتصل بالراوتر أولاً.'; });
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await Future.wait<List<Map<String, String>>>([
        client.command('/ip/firewall/nat/print'),
        client.command('/ip/firewall/address-list/print'),
      ]);
      if (!mounted) return;
      setState(() { _client = client; _nat = rows[0]; _addresses = rows[1]; _loading = false; });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = _friendly(error); });
    }
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success), backgroundColor: const Color(0xFF176D58)));
      await _load();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشلت العملية: ${_friendly(error)}'), backgroundColor: const Color(0xFF8C3042)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, String>?> _form(String title, List<_NatField> fields) async {
    final controllers = <String, TextEditingController>{for (final field in fields) field.key: TextEditingController(text: field.initial)};
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<Map<String, String>>(context: context, builder: (dialogContext) => AlertDialog(
      backgroundColor: _natPanel,
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      content: SizedBox(width: 460, child: Form(key: formKey, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final field in fields)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: TextFormField(
            controller: controllers[field.key],
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),
            decoration: InputDecoration(labelText: field.label, hintText: field.hint, helperText: field.helper),
            validator: field.required ? (value) => value == null || value.trim().isEmpty ? 'هذا الحقل مطلوب' : null : null,
          )),
      ])))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
        FilledButton(onPressed: () {
          if (formKey.currentState?.validate() != true) return;
          Navigator.pop(dialogContext, {for (final field in fields) field.key: controllers[field.key]!.text.trim()});
        }, child: const Text('حفظ')),
      ],
    ));
    for (final controller in controllers.values) { controller.dispose(); }
    return result;
  }

  Future<bool> _confirm(String title, String detail) async => await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
    backgroundColor: _natPanel,
    title: Text(title, style: const TextStyle(color: Colors.white)),
    content: Text(detail, style: const TextStyle(color: _natMuted, height: 1.4)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
      FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('تأكيد')),
    ],
  )) ?? false;

  Future<void> _addNat() async {
    final data = await _form('إضافة قاعدة NAT', const <_NatField>[
      _NatField('chain', 'Chain', required: true, initial: 'srcnat', hint: 'srcnat / dstnat'),
      _NatField('action', 'Action', required: true, initial: 'masquerade', hint: 'masquerade / dst-nat / src-nat / redirect'),
      _NatField('out-interface', 'Out Interface', hint: 'ether1 (لـ masquerade)'),
      _NatField('in-interface', 'In Interface', hint: 'bridge-lan'),
      _NatField('protocol', 'Protocol', hint: 'tcp / udp'),
      _NatField('dst-port', 'Destination Port', hint: '443 أو 8080-8090'),
      _NatField('dst-address', 'Destination Address'),
      _NatField('to-addresses', 'To Addresses', hint: '192.168.88.10 (لـ dst-nat)'),
      _NatField('to-ports', 'To Ports', hint: '8443'),
      _NatField('comment', 'Comment'),
    ]);
    if (data == null || _client == null) return;
    if (!await _confirm('إضافة قاعدة NAT؟', 'ستُضاف القاعدة إلى الراوتر مباشرة وقد تؤثر على التوجيه أو تعريض خدمة للإنترنت. راجع Chain وAction والمنافذ قبل المتابعة.')) return;
    await _run(() async {
      final args = <String, String>{};
      for (final entry in data.entries) {
        if (entry.value.isNotEmpty) args[entry.key] = entry.value;
      }
      await _client!.verifiedCommand('/ip/firewall/nat/add', args: args);
    }, 'تمت إضافة قاعدة NAT.');
  }

  Future<void> _toggleNat(Map<String, String> row) async {
    final id = row['.id'];
    if (id == null || _client == null) return;
    final disabled = _truth(row['disabled']);
    await _run(() async {
      await _client!.verifiedCommand(disabled ? '/ip/firewall/nat/enable' : '/ip/firewall/nat/disable', args: <String, String>{'.id': id});
    }, disabled ? 'تم تفعيل قاعدة NAT.' : 'تم تعطيل قاعدة NAT.');
  }

  Future<void> _removeNat(Map<String, String> row) async {
    final id = row['.id'];
    if (id == null || _client == null) return;
    if (!await _confirm('حذف قاعدة NAT؟', '${row['chain'] ?? ''} / ${row['action'] ?? ''} — الحذف نهائي من إعدادات الراوتر.')) return;
    await _run(() async {
      await _client!.verifiedCommand('/ip/firewall/nat/remove', args: <String, String>{'.id': id});
    }, 'تم حذف قاعدة NAT.');
  }

  Future<void> _addAddressList() async {
    final data = await _form('إضافة عنوان إلى Address List', const <_NatField>[
      _NatField('list', 'اسم القائمة', required: true, hint: 'blocked / bypass / disconnected'),
      _NatField('address', 'IP أو شبكة CIDR', required: true, hint: '192.168.10.50 أو 192.168.10.0/24'),
      _NatField('timeout', 'Timeout اختياري', hint: '30m / 12h / 1d', helper: 'اتركه فارغاً للإدخال الدائم'),
      _NatField('comment', 'Comment'),
    ]);
    if (data == null || _client == null) return;
    if (!await _confirm('إضافة عنوان للقائمة؟', 'تحقق من اسم القائمة والقواعد التي تستخدمها. إدخال العنوان في القائمة لا يضمن الحظر إلا إذا كانت قواعد Firewall أو RAW تشير إلى هذه القائمة.')) return;
    await _run(() async {
      final args = <String, String>{'list': data['list']!, 'address': data['address']!};
      for (final key in <String>['timeout', 'comment']) {
        if ((data[key] ?? '').isNotEmpty) args[key] = data[key]!;
      }
      await _client!.verifiedCommand('/ip/firewall/address-list/add', args: args);
    }, 'تمت إضافة العنوان إلى Address List.');
  }

  Future<void> _removeAddress(Map<String, String> row) async {
    final id = row['.id'];
    if (id == null || _client == null) return;
    if (!await _confirm('حذف عنوان من القائمة؟', '${row['address'] ?? ''} من ${row['list'] ?? ''}')) return;
    await _run(() async {
      await _client!.verifiedCommand('/ip/firewall/address-list/remove', args: <String, String>{'.id': id});
    }, 'تم حذف العنوان.');
  }

  List<String> get _listNames {
    final names = _addresses.map((row) => (row['list'] ?? '').trim()).where((value) => value.isNotEmpty).toSet().toList()..sort();
    return <String>['الكل', ...names];
  }

  List<Map<String, String>> get _filteredAddresses => _addresses.where((row) {
    final name = row['list'] ?? '';
    final query = _search.trim().toLowerCase();
    return (_listFilter == 'الكل' || name == _listFilter) &&
      (query.isEmpty || '${row['address'] ?? ''} ${row['list'] ?? ''} ${row['comment'] ?? ''}'.toLowerCase().contains(query));
  }).toList(growable: false);

  Widget _panel(String title, Widget child, {Widget? action}) => Container(
    margin: const EdgeInsets.only(bottom: 11), padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(color: _natPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(.06))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))), if (action != null) action]),
      const SizedBox(height: 10), child,
    ]),
  );

  Widget _record(String title, String subtitle, {required IconData icon, required Color color, List<Widget> actions = const <Widget>[]}) => Container(
    margin: const EdgeInsets.only(bottom: 7), padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(11)),
    child: Row(children: [
      Icon(icon, color: color, size: 20), const SizedBox(width: 9),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4), Text(subtitle, style: const TextStyle(color: _natMuted, fontSize: 10)),
      ])),
      ...actions,
    ]),
  );

  Widget _empty(String text) => Padding(padding: const EdgeInsets.all(18), child: Center(child: Text(text, style: const TextStyle(color: _natMuted))));

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Scaffold(backgroundColor: _natBg, body: Center(child: Text('اتصل بالراوتر أولاً.', style: TextStyle(color: Colors.white))));
    return Scaffold(
      backgroundColor: _natBg,
      appBar: AppBar(
        backgroundColor: _natBg, foregroundColor: Colors.white, title: const Text('NAT • Address Lists'),
        actions: [IconButton(onPressed: _busy || _loading ? null : _load, icon: const Icon(Icons.refresh_rounded))],
        bottom: TabBar(controller: _tabs, isScrollable: true, indicatorColor: _natAccent, tabs: const [
          Tab(icon: Icon(Icons.swap_horiz_rounded, size: 17), text: 'Firewall NAT'),
          Tab(icon: Icon(Icons.list_alt_rounded, size: 17), text: 'Address Lists'),
        ]),
      ),
      body: _loading ? const Center(child: CircularProgressIndicator(color: _natAccent)) : Column(children: [
        if (_error != null) Container(width: double.infinity, padding: const EdgeInsets.all(10), color: const Color(0xFF3A1721), child: Text(_error!, style: const TextStyle(color: _natRed, fontSize: 12))),
        Expanded(child: TabBarView(controller: _tabs, children: [_natTab(), _addressTab()])),
      ]),
    );
  }

  Widget _natTab() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('قواعد Firewall NAT (${_nat.length})', Column(children: [
      if (_nat.isEmpty) _empty('لا توجد قواعد NAT أو لم يتم تحميلها.')
      else ..._nat.map((row) {
        final disabled = _truth(row['disabled']);
        final details = <String>[
          if ((row['src-address'] ?? '').isNotEmpty) 'src ${row['src-address']}',
          if ((row['dst-address'] ?? '').isNotEmpty) 'dst ${row['dst-address']}',
          if ((row['protocol'] ?? '').isNotEmpty) row['protocol']!,
          if ((row['dst-port'] ?? '').isNotEmpty) 'port ${row['dst-port']}',
          if ((row['out-interface'] ?? '').isNotEmpty) 'out ${row['out-interface']}',
          if ((row['to-addresses'] ?? '').isNotEmpty) '→ ${row['to-addresses']}',
          if ((row['to-ports'] ?? '').isNotEmpty) 'to-port ${row['to-ports']}',
        ].join(' • ');
        return _record('${row['chain'] ?? '—'} / ${row['action'] ?? '—'}', '${disabled ? 'معطلة' : 'مفعّلة'} • ${details.isEmpty ? 'بدون تفاصيل إضافية' : details} • ${row['comment'] ?? ''}',
          icon: Icons.swap_horiz_rounded, color: disabled ? _natRed : _natGreen, actions: [
            IconButton(tooltip: disabled ? 'تفعيل' : 'تعطيل', onPressed: _busy ? null : () => _toggleNat(row), icon: Icon(disabled ? Icons.play_arrow_rounded : Icons.pause_rounded, color: _natAccent, size: 19)),
            IconButton(tooltip: 'حذف', onPressed: _busy ? null : () => _removeNat(row), icon: const Icon(Icons.delete_outline, color: _natRed, size: 19)),
          ]);
      }),
    ]), action: IconButton(onPressed: _busy ? null : _addNat, icon: const Icon(Icons.add_circle_outline, color: _natAccent))),
  ]);

  Widget _addressTab() => ListView(padding: const EdgeInsets.all(12), children: [
    _panel('فلترة العناوين', Column(children: [
      DropdownButtonFormField<String>(
        value: _listNames.contains(_listFilter) ? _listFilter : 'الكل',
        dropdownColor: _natPanel, style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(labelText: 'اسم القائمة (list)'),
        items: _listNames.map((name) => DropdownMenuItem<String>(value: name, child: Text(name))).toList(),
        onChanged: (value) => setState(() => _listFilter = value ?? 'الكل'),
      ),
      const SizedBox(height: 8),
      TextField(style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'بحث بعنوان IP أو تعليق', prefixIcon: Icon(Icons.search_rounded)), onChanged: (value) => setState(() => _search = value)),
    ]), action: IconButton(onPressed: _busy ? null : _addAddressList, icon: const Icon(Icons.add_circle_outline, color: _natAccent))),
    _panel('Address List (${_filteredAddresses.length})', Column(children: [
      if (_filteredAddresses.isEmpty) _empty('لا توجد عناوين تطابق الفلتر.')
      else ..._filteredAddresses.map((row) => _record(row['address'] ?? '—',
        '${row['list'] ?? '—'} • timeout: ${row['timeout'] ?? 'دائم/غير معروض'} • ${row['comment'] ?? ''}',
        icon: Icons.shield_outlined, color: _natGreen, actions: [
          IconButton(tooltip: 'حذف', onPressed: _busy ? null : () => _removeAddress(row), icon: const Icon(Icons.delete_outline, color: _natRed, size: 19)),
        ])),
    ])),
    const Padding(padding: EdgeInsets.fromLTRB(4, 0, 4, 16), child: Text('تنبيه: وجود عنوان في القائمة لا يحظره تلقائياً؛ يجب أن تستعمله قاعدة Firewall أو RAW. مدة timeout اختيارية، واتركها فارغة للإدخال الدائم.', style: TextStyle(color: _natMuted, fontSize: 11, height: 1.4))),
  ]);
}

class _NatField {
  const _NatField(this.key, this.label, {this.required = false, this.initial = '', this.hint = '', this.helper = ''});
  final String key;
  final String label;
  final bool required;
  final String initial;
  final String hint;
  final String helper;
}
