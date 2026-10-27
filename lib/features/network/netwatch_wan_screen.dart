import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _nwBg = Color(0xFF080B12);
const Color _nwPanel = Color(0xFF111722);
const Color _nwMuted = Color(0xFF8D9AB0);
const Color _nwAccent = Color(0xFF8B7CFF);
const Color _nwGreen = Color(0xFF43D9A3);
const Color _nwRed = Color(0xFFFF657A);

class NetwatchWanScreen extends ConsumerStatefulWidget {
  const NetwatchWanScreen({super.key});

  @override
  ConsumerState<NetwatchWanScreen> createState() => _NetwatchWanScreenState();
}

class _NetwatchWanScreenState extends ConsumerState<NetwatchWanScreen> {
  RouterOsClient? _client;
  List<Map<String, String>> _items = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = ref.read(activeRouterClientProvider);
    if (_client != null) _load();
    else { _loading = false; _error = 'لا يوجد راوتر متصل.'; }
  }

  Future<void> _load() async {
    final client = _client;
    if (client == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await client.command('/tool/netwatch/print');
      if (!mounted) return;
      setState(() { _items = rows; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = _friendly(e); });
    }
  }

  String _friendly(Object e) => e.toString().replaceFirst('RouterOsException: ', '').replaceFirst('Exception: ', '');

  Future<void> _add() async {
    final host = TextEditingController();
    final interval = TextEditingController(text: '00:00:10');
    final up = TextEditingController();
    final down = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final data = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _nwPanel,
        title: const Text('إضافة Netwatch', style: TextStyle(color: Colors.white)),
        content: SizedBox(width: 460, child: Form(
          key: formKey,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: host, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Host / IP', hintText: '1.1.1.1'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'أدخل عنوان الفحص' : null),
            TextFormField(controller: interval, style: const TextStyle(color: Colors.white, fontFamily: 'monospace'), decoration: const InputDecoration(labelText: 'Interval', hintText: '00:00:10'),
              validator: (v) => (v == null || !RegExp(r'^\d{2,}:[0-5]\d:[0-5]\d(?:\.\d{1,3})?$').hasMatch(v.trim())) ? 'استخدم صيغة HH:MM:SS' : null),
            const SizedBox(height: 8),
            TextFormField(controller: up, minLines: 2, maxLines: 4, style: const TextStyle(color: _nwGreen, fontFamily: 'monospace', fontSize: 12), decoration: const InputDecoration(labelText: 'up-script (اختياري)', hintText: '/log warning "Netwatch: WAN UP"', alignLabelWithHint: true)),
            const SizedBox(height: 8),
            TextFormField(controller: down, minLines: 2, maxLines: 4, style: const TextStyle(color: _nwRed, fontFamily: 'monospace', fontSize: 12), decoration: const InputDecoration(labelText: 'down-script (اختياري)', hintText: '/log warning "Netwatch: WAN DOWN"', alignLabelWithHint: true)),
            const SizedBox(height: 8),
            const Text('السكربتات تُنفّذ بصلاحيات الراوتر. راجعها قبل الحفظ، ولا تستخدم التبديل التلقائي إلا بعد اختبار المسارات والـ routing marks.', style: TextStyle(color: _nwMuted, fontSize: 11)),
          ]))),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(onPressed: () {
            if (formKey.currentState?.validate() != true) return;
            Navigator.pop(ctx, {'host':host.text.trim(),'interval':interval.text.trim(),'up-script':up.text,'down-script':down.text});
          }, child: const Text('إضافة')),
        ],
      ),
    );
    host.dispose(); interval.dispose(); up.dispose(); down.dispose();
    if (data == null || _client == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _nwPanel,
        title: const Text('تأكيد إنشاء المراقب', style: TextStyle(color: Colors.white)),
        content: Text('سيُضاف Netwatch للعنوان ${data['host']} مع سكربتات الحالة المدخلة. هل تريد المتابعة؟', style: const TextStyle(color: _nwMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تنفيذ على الراوتر')),
        ],
      ),
    ) ?? false;
    if (!confirmed) return;
    setState(() => _busy = true);
    try {
      await _client!.command('/tool/netwatch/add', args: data);
      await _load();
      if (mounted) _message('تم إرسال أمر إضافة Netwatch.');
    } catch (e) {
      if (mounted) _message('فشلت الإضافة: ${_friendly(e)}', error: true);
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _remove(Map<String, String> item) async {
    final id = item['.id'];
    if (id == null || id.isEmpty || _client == null) {
      _message('لم يُرجع الراوتر معرّف المراقب.', error: true); return;
    }
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: _nwPanel,
      title: const Text('حذف مراقب Netwatch؟', style: TextStyle(color: Colors.white)),
      content: Text('سيُحذف الفحص للعنوان ${item['host'] ?? '—'} من إعدادات الراوتر.', style: const TextStyle(color: _nwMuted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
      ],
    )) ?? false;
    if (!ok) return;
    try {
      await _client!.command('/tool/netwatch/remove', args: {'.id': id});
      await _load();
      if (mounted) _message('تم حذف المراقب.');
    } catch (e) { if (mounted) _message('فشل الحذف: ${_friendly(e)}', error: true); }
  }

  void _message(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), backgroundColor: error ? const Color(0xFF8C3042) : const Color(0xFF176D58)));
  }

  @override
  Widget build(BuildContext context) {
    final active = ref.watch(activeRouterClientProvider);
    if (active == null || !identical(active, _client)) {
      return const Scaffold(backgroundColor: _nwBg, body: Center(child: Text('اتصل بالراوتر أولاً.', style: TextStyle(color: Colors.white))));
    }
    return Scaffold(
      backgroundColor: _nwBg,
      appBar: AppBar(backgroundColor: _nwBg, foregroundColor: Colors.white, title: const Text('Netwatch • WAN Monitor'),
        actions: [IconButton(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh_rounded)), IconButton(onPressed: _busy ? null : _add, icon: const Icon(Icons.add_circle_outline_rounded))]),
      body: Column(children: [
        Container(margin: const EdgeInsets.fromLTRB(12, 4, 12, 10), padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _nwPanel, borderRadius: BorderRadius.circular(16), border: Border.all(color: _nwAccent.withOpacity(.25))),
          child: Row(children: [
            const Icon(Icons.monitor_heart_outlined, color: _nwAccent, size: 28), const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('مراقبة بوابات وخطوط WAN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
              Text('عدد نقاط الفحص: ${_items.length} • الحالة حسب آخر رد من RouterOS', style: const TextStyle(color: _nwMuted, fontSize: 11)),
            ])),
            FilledButton.tonalIcon(onPressed: _busy ? null : _add, icon: const Icon(Icons.add, size: 17), label: const Text('إضافة')),
          ])),
        if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: const TextStyle(color: _nwRed))),
        if (_loading) const LinearProgressIndicator(color: _nwAccent),
        Expanded(child: _items.isEmpty && !_loading
          ? const Center(child: Text('لا توجد نقاط Netwatch. أضف Host لمراقبة الاتصال.', style: TextStyle(color: _nwMuted)),)
          : RefreshIndicator(color: _nwAccent, onRefresh: _load, child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
            itemCount: _items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) {
              final item = _items[i];
              final status = (item['status'] ?? item['state'] ?? '').toLowerCase();
              final isUp = status == 'up' || status == 'reachable';
              final disabled = item['disabled'] == 'true';
              final color = disabled ? _nwMuted : isUp ? _nwGreen : _nwRed;
              return Container(padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: _nwPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: color.withOpacity(.3))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(disabled ? Icons.pause_circle_outline : isUp ? Icons.check_circle_outline : Icons.error_outline, color: color),
                    const SizedBox(width: 8),
                    Expanded(child: Text(item['host'] ?? item['comment'] ?? 'Host غير معروف', style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.w800))),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5), decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(9)),
                      child: Text(disabled ? 'DISABLED' : isUp ? 'UP' : (status.isEmpty ? 'UNKNOWN' : 'DOWN'), style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900))),
                    IconButton(tooltip: 'حذف المراقب', onPressed: _busy ? null : () => _remove(item), icon: const Icon(Icons.delete_outline, color: _nwMuted, size: 19)),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 5, children: [
                    _metric('الفترة', item['interval'] ?? '—'),
                    _metric('آخر تغيير / since', item['since'] ?? item['last-down-time'] ?? item['last-down'] ?? 'غير متاح'),
                    _metric('Timeout', item['timeout'] ?? '—'),
                  ]),
                  if ((item['comment'] ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 7), child: Text(item['comment']!, style: const TextStyle(color: _nwMuted, fontSize: 11))),
                ]),
              );
            },
          ))),
      ]),
    );
  }

  Widget _metric(String label, String value) => Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(8)),
    child: Text('$label: $value', style: const TextStyle(color: _nwMuted, fontSize: 10)));
}
