import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const _accent = Color(0xFF8B7CFF);
const _panel = Color(0xFF111722);
const _muted = Color(0xFF8D9AB0);
const _green = Color(0xFF43D9A3);
const _red = Color(0xFFFF657A);

class DhcpBindingScreen extends ConsumerWidget {
  const DhcpBindingScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Center(child: Text('اتصل براوتر أولًا.'));
    return DefaultTabController(length: 2, child: Column(children: [
      const TabBar(isScrollable: true, tabs: [
        Tab(icon: Icon(Icons.router_rounded), text: 'DHCP Leases'),
        Tab(icon: Icon(Icons.rule_rounded), text: 'Hotspot IP Bindings'),
      ]),
      Expanded(child: TabBarView(children: [
        _Leases(client: client), _Bindings(client: client),
      ])),
    ]));
  }
}

class _Leases extends StatefulWidget {
  const _Leases({required this.client});
  final RouterOsClient client;
  @override
  State<_Leases> createState() => _LeasesState();
}

class _LeasesState extends State<_Leases> {
  List<Map<String,String>> _rows = [];
  bool _loading = true, _reading = false;
  String? _error;
  Timer? _timer;
  final Set<String> _busy = {};
  final _search = TextEditingController();

  @override
  void initState() { super.initState(); unawaited(_load()); _timer = Timer.periodic(const Duration(seconds: 8), (_) { if (mounted && !_reading) unawaited(_load(silent: true)); }); }
  @override
  void dispose() { _timer?.cancel(); _search.dispose(); super.dispose(); }

  Future<void> _load({bool silent = false}) async {
    if (_reading) return; _reading = true;
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command('/ip/dhcp-server/lease/print', args: const {
        '.proplist': '.id,address,mac-address,host-name,server,status,dynamic,disabled,comment,block-access,rate-limit',
      });
      if (mounted) setState(() { _rows = rows; _loading = false; _error = null; });
    } catch (e) { if (mounted) setState(() { _loading = false; _error = _friendly(e); }); }
    finally { _reading = false; }
  }

  Future<void> _op(Map<String,String> row, String operation, Map<String,String> args, String success) async {
    final id = row['.id'] ?? '';
    if (id.isEmpty || _busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await widget.client.command('/ip/dhcp-server/lease/' + operation, args: {if (operation == 'make-static') 'numbers': id else '.id': id, ...args});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
      await _load();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(e)), backgroundColor: _red)); }
    finally { if (mounted) setState(() => _busy.remove(id)); }
  }

  Future<void> _rate(Map<String,String> row) async {
    final controller = TextEditingController(text: row['rate-limit'] ?? '');
    final result = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('تحديد سرعة الجهاز'),
      content: TextField(controller: controller, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'Rate limit', hintText: '5M/20M')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('حفظ')),
      ],
    ));
    controller.dispose();
    if (result == null) return;
    if (result.isNotEmpty && !RegExp(r'^\d+(?:\.\d+)?[kKmMgG]?(?:/\d+(?:\.\d+)?[kKmMgG]?)?$').hasMatch(result)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('صيغة السرعة غير صحيحة، مثال 5M/20M'), backgroundColor: _red)); return;
    }
    await _op(row, 'set', {'rate-limit': result}, result.isEmpty ? 'تم حذف حد السرعة.' : 'تم تحديث السرعة.');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _rows.isEmpty) return _Retry(title: 'تعذر تحميل DHCP Leases', error: _error!, retry: () => _load());
    final query = _search.text.trim().toLowerCase();
    final rows = _rows.where((r) => query.isEmpty || [r['address'] ?? '',r['mac-address'] ?? '',r['host-name'] ?? '',r['comment'] ?? ''].any((v) => v.toLowerCase().contains(query))).toList();
    return RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(12), children: [
      _Header(title: 'DHCP Leases', count: _rows.length, refresh: () => _load()),
      TextField(controller: _search, onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'ابحث بالاسم أو IP أو MAC')),
      const SizedBox(height: 8),
      if (_error != null) Text(_error!, style: const TextStyle(color: _red)),
      if (rows.isEmpty) const Text('لا توجد أجهزة مطابقة.', style: TextStyle(color: _muted)),
      ...rows.map((r) {
        final id = r['.id'] ?? '';
        final busy = _busy.contains(id);
        final dynamicLease = r['dynamic'] == 'true';
        final blocked = r['block-access'] == 'yes' || r['block-access'] == 'true';
        final name = (r['host-name'] ?? '').isEmpty ? 'جهاز بدون اسم' : r['host-name']!;
        return Card(color: _panel, child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          Text('IP: ' + (r['address'] ?? '—'), textDirection: TextDirection.ltr, style: const TextStyle(color: _green)),
          Text('MAC: ' + (r['mac-address'] ?? '—'), textDirection: TextDirection.ltr, style: const TextStyle(color: _muted)),
          if ((r['server'] ?? '').isNotEmpty) Text('Server: ' + r['server']!, style: const TextStyle(color: _muted)),
          Wrap(spacing: 5, children: [
            TextButton.icon(onPressed: busy || !dynamicLease ? null : () => _op(r, 'make-static', const {}, 'تم تثبيت عنوان IP.'), icon: const Icon(Icons.push_pin), label: const Text('تثبيت IP')),
            TextButton.icon(onPressed: busy ? null : () => _rate(r), icon: const Icon(Icons.speed), label: const Text('السرعة')),
            TextButton.icon(onPressed: busy ? null : () => _op(r, 'set', {'block-access': blocked ? 'no' : 'yes'}, blocked ? 'تم رفع الحظر.' : 'تم حظر الجهاز.'), icon: Icon(blocked ? Icons.lock_open : Icons.block, color: blocked ? _green : _red), label: Text(blocked ? 'رفع الحظر' : 'حظر')),
          ]),
          if (busy) const LinearProgressIndicator(),
        ])));
      }),
    ]));
  }
}

class _Bindings extends StatefulWidget {
  const _Bindings({required this.client});
  final RouterOsClient client;
  @override
  State<_Bindings> createState() => _BindingsState();
}

class _BindingsState extends State<_Bindings> {
  List<Map<String,String>> _rows = [];
  bool _loading = true, _reading = false;
  String? _error;
  final Set<String> _busy = {};

  @override
  void initState() { super.initState(); unawaited(_load()); }
  Future<void> _load() async {
    if (_reading) return; _reading = true;
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command('/ip/hotspot/ip-binding/print', args: const {
        '.proplist': '.id,mac-address,address,server,type,disabled,comment,dynamic',
      });
      if (mounted) setState(() { _rows = rows; _loading = false; _error = null; });
    } catch (e) { if (mounted) setState(() { _loading = false; _error = _friendly(e); }); }
    finally { _reading = false; }
  }

  Future<void> _add() async {
    final mac = TextEditingController(), ip = TextEditingController(), server = TextEditingController(), comment = TextEditingController();
    var type = 'bypassed';
    final formKey = GlobalKey<FormState>();
    final values = await showDialog<Map<String,String>>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => AlertDialog(
      title: const Text('إضافة IP Binding'),
      content: SingleChildScrollView(child: Form(key: formKey, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextFormField(controller: mac, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'MAC Address'), validator: (v) {
          final s = (v ?? '').trim(); if (s.isNotEmpty && !RegExp(r'^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$').hasMatch(s)) return 'صيغة MAC غير صحيحة';
          if (s.isEmpty && ip.text.trim().isEmpty) return 'أدخل MAC أو IP'; return null;
        }),
        TextFormField(controller: ip, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'IP Address'), validator: (v) {
          final s = (v ?? '').trim(); if (s.isNotEmpty && !RegExp(r'^[0-9a-fA-F:.]+(?:/\d{1,3})?$').hasMatch(s)) return 'صيغة IP غير صحيحة';
          if (s.isEmpty && mac.text.trim().isEmpty) return 'أدخل IP أو MAC'; return null;
        }),
        TextField(controller: server, decoration: const InputDecoration(labelText: 'Hotspot Server (اختياري)')),
        DropdownButtonFormField<String>(value: type, decoration: const InputDecoration(labelText: 'النوع'), items: const [
          DropdownMenuItem(value: 'bypassed', child: Text('Bypassed — تخطي الدخول')),
          DropdownMenuItem(value: 'blocked', child: Text('Blocked — حظر')),
          DropdownMenuItem(value: 'regular', child: Text('Regular — عادي')),
        ], onChanged: (v) { if (v != null) refresh(() => type = v); }),
        TextField(controller: comment, decoration: const InputDecoration(labelText: 'ملاحظة')),
      ]))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(onPressed: () {
          if (formKey.currentState?.validate() != true) return;
          Navigator.pop(ctx, <String,String>{
            if (mac.text.trim().isNotEmpty) 'mac-address': mac.text.trim().toUpperCase(),
            if (ip.text.trim().isNotEmpty) 'address': ip.text.trim(),
            if (server.text.trim().isNotEmpty) 'server': server.text.trim(),
            'type': type,
            if (comment.text.trim().isNotEmpty) 'comment': comment.text.trim(),
          });
        }, child: const Text('إضافة')),
      ],
    )));
    mac.dispose(); ip.dispose(); server.dispose(); comment.dispose();
    if (values == null) return;
    try {
      await widget.client.command('/ip/hotspot/ip-binding/add', args: values);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تمت إضافة IP Binding.')));
      await _load();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(e)), backgroundColor: _red)); }
  }

  Future<void> _toggle(Map<String,String> row) async {
    final id = row['.id'] ?? '';
    if (id.isEmpty || row['dynamic'] == 'true' || _busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      final disabled = row['disabled'] == 'true';
      await widget.client.command('/ip/hotspot/ip-binding/set', args: {'.id': id, 'disabled': disabled ? 'no' : 'yes'});
      await _load();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(e)), backgroundColor: _red)); }
    finally { if (mounted) setState(() => _busy.remove(id)); }
  }

  Future<void> _delete(Map<String,String> row) async {
    final id = row['.id'] ?? '';
    if (id.isEmpty || row['dynamic'] == 'true') return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('حذف القاعدة؟'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف'))],
    ));
    if (ok != true) return;
    try { await widget.client.command('/ip/hotspot/ip-binding/remove', args: {'.id': id}); await _load(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_friendly(e)), backgroundColor: _red)); }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty) return const Center(child: CircularProgressIndicator());
    if (_error != null && _rows.isEmpty) return _Retry(title: 'تعذر تحميل IP Bindings', error: _error!, retry: _load);
    return RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(12), children: [
      _Header(title: 'Hotspot IP Bindings', count: _rows.length, refresh: _load, add: _add),
      if (_error != null) Text(_error!, style: const TextStyle(color: _red)),
      if (_rows.isEmpty) const Text('لا توجد قواعد. استخدم + لإضافة Bypassed أو Blocked أو Regular.', style: TextStyle(color: _muted)),
      ..._rows.map((r) {
        final id = r['.id'] ?? '';
        final type = r['type'] ?? 'regular';
        final color = type == 'blocked' ? _red : type == 'bypassed' ? _green : _accent;
        return Card(color: _panel, child: ListTile(
          leading: Icon(type == 'blocked' ? Icons.block : type == 'bypassed' ? Icons.verified_user : Icons.rule, color: color),
          title: Text((r['mac-address'] ?? '').isNotEmpty ? r['mac-address']! : (r['address'] ?? 'بدون عنوان'), style: const TextStyle(color: Colors.white), textDirection: TextDirection.ltr),
          subtitle: Text([type.toUpperCase(), if ((r['address'] ?? '').isNotEmpty) 'IP: ' + r['address']!, if ((r['server'] ?? '').isNotEmpty) 'Server: ' + r['server']!, if ((r['comment'] ?? '').isNotEmpty) r['comment']!].join(' · '), style: const TextStyle(color: _muted)),
          trailing: PopupMenuButton<String>(onSelected: (v) { if (v == 'toggle') _toggle(r); if (v == 'delete') _delete(r); }, itemBuilder: (_) => const [
            PopupMenuItem(value: 'toggle', child: Text('تفعيل / تعطيل')),
            PopupMenuItem(value: 'delete', child: Text('حذف')),
          ]),
        ));
      }),
    ]));
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.count, required this.refresh, this.add});
  final String title; final int count; final VoidCallback refresh; final VoidCallback? add;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(color: const Color(0xFF292647), borderRadius: BorderRadius.circular(14)),
    child: Row(children: [
      const Icon(Icons.hub, color: _accent), const SizedBox(width: 9),
      Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
      Text(count.toString(), style: const TextStyle(color: _green, fontWeight: FontWeight.bold)),
      IconButton(onPressed: refresh, icon: const Icon(Icons.refresh, color: _accent)),
      if (add != null) IconButton(onPressed: add, icon: const Icon(Icons.add_circle, color: _green)),
    ]),
  );
}

class _Retry extends StatelessWidget {
  const _Retry({required this.title, required this.error, required this.retry});
  final String title, error; final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
    const SizedBox(height: 8), Text(error, textAlign: TextAlign.center, style: const TextStyle(color: _muted)),
    TextButton.icon(onPressed: retry, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
  ])));
}

String _friendly(Object error) {
  if (error is TimeoutException) return 'انتهت مهلة الاتصال بالراوتر.';
  if (error is RouterOsException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
