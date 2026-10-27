import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _salesBg = Color(0xFF080B12);
const Color _salesPanel = Color(0xFF111722);
const Color _salesMuted = Color(0xFF8D9AB0);
const Color _salesAccent = Color(0xFF8B7CFF);
const Color _salesGreen = Color(0xFF43D9A3);
const Color _salesRed = Color(0xFFFF657A);

class HotspotSalesReportScreen extends ConsumerStatefulWidget {
  const HotspotSalesReportScreen({super.key, this.client});
  final RouterOsClient? client;

  @override
  ConsumerState<HotspotSalesReportScreen> createState() => _HotspotSalesReportScreenState();
}

class _HotspotSalesReportScreenState extends ConsumerState<HotspotSalesReportScreen> {
  RouterOsClient? _client;
  List<Map<String, String>> _users = [];
  List<Map<String, String>> _profiles = [];
  List<Map<String, String>> _secrets = [];
  bool _loading = true;
  String? _error;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? ref.read(activeRouterClientProvider);
    if (_client != null) _load();
    else { _loading = false; _error = 'لا يوجد راوتر متصل.'; }
  }

  String _friendly(Object e) => e.toString().replaceFirst('RouterOsException: ', '').replaceFirst('Exception: ', '');

  Future<void> _load() async {
    final client = _client;
    if (client == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await Future.wait<List<Map<String, String>>>([
        client.command('/ip/hotspot/user/print'),
        client.command('/ip/hotspot/user/profile/print'),
        client.command('/ppp/secret/print'),
      ]);
      if (!mounted) return;
      setState(() { _users = result[0]; _profiles = result[1]; _secrets = result[2]; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = _friendly(e); });
    }
  }

  String _priceFromComment(String comment) {
    final match = RegExp(r'(?:NOVA-PRICE=|PRICE=|price\s*[:=]\s*)([^|;,\s]+)', caseSensitive: false).firstMatch(comment);
    return match?.group(1) ?? '';
  }

  double? _price(String raw) {
    final normalized = raw.replaceAll(',', '').replaceAll(RegExp(r'[^0-9.\-]'), '');
    final value = double.tryParse(normalized);
    return value != null && value >= 0 ? value : null;
  }

  bool _expired(Map<String, String> user) {
    final comment = (user['comment'] ?? '').toLowerCase();
    if (comment.contains('nova_expired')) return true;
    final limit = (user['limit-uptime'] ?? '').trim();
    final uptime = (user['uptime'] ?? '').trim();
    final limitSeconds = _durationSeconds(limit);
    final uptimeSeconds = _durationSeconds(uptime);
    if (limitSeconds != null && uptimeSeconds != null && limitSeconds > 0 && uptimeSeconds >= limitSeconds) return true;
    return false;
  }

  int? _durationSeconds(String value) {
    if (value.isEmpty) return null;
    final regex = RegExp(r'(?:(\d+)w)?(?:(\d+)d)?(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$');
    final m = regex.firstMatch(value);
    if (m == null || m.group(0)!.isEmpty) return null;
    return (int.tryParse(m.group(1) ?? '') ?? 0) * 604800 +
      (int.tryParse(m.group(2) ?? '') ?? 0) * 86400 +
      (int.tryParse(m.group(3) ?? '') ?? 0) * 3600 +
      (int.tryParse(m.group(4) ?? '') ?? 0) * 60 +
      (int.tryParse(m.group(5) ?? '') ?? 0);
  }

  Future<void> _deleteBatch(String batchId, List<Map<String, String>> batchRows) async {
    if (batchRows.isEmpty || _client == null) return;
    final selected = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: _salesPanel,
      title: const Text('حذف دفعة الكروت بالكامل؟', style: TextStyle(color: Colors.white)),
      content: Text('سيتم حذف ${batchRows.length} كرت من دفعة NOVA-BATCH=$batchId نهائياً من الراوتر. هذه العملية لا يمكن التراجع عنها.', style: const TextStyle(color: _salesMuted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: _salesRed), onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف الدفعة')),
      ],
    )) ?? false;
    if (!selected) return;
    setState(() => _deleting = true);
    var removed = 0;
    final errors = <String>[];
    try {
      for (final row in batchRows) {
        final id = row['.id'];
        if (id == null || id.isEmpty) { errors.add(row['name'] ?? '?'); continue; }
        try {
          await _client!.command('/ip/hotspot/user/remove', args: {'.id': id});
          removed++;
        } catch (e) { errors.add('${row['name'] ?? id}: ${_friendly(e)}'); }
      }
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(errors.isEmpty ? 'تم حذف $removed كرت.' : 'حُذف $removed كرت، وفشل حذف ${errors.length}.'),
        backgroundColor: errors.isEmpty ? const Color(0xFF176D58) : const Color(0xFF8C3042),
      ));
    } finally { if (mounted) setState(() => _deleting = false); }
  }

  @override
  Widget build(BuildContext context) {
    final activeClient = ref.watch(activeRouterClientProvider);
    if (_client == null || (activeClient != null && !identical(activeClient, _client))) {
      return const Scaffold(backgroundColor: _salesBg, body: Center(child: Text('اتصل بالراوتر أولاً.', style: TextStyle(color: Colors.white))));
    }
    final profilePrices = <String, double>{};
    for (final profile in _profiles) {
      final comment = profile['comment'] ?? '';
      final raw = _priceFromComment(comment);
      final price = _price(raw);
      if (price != null) profilePrices[profile['name'] ?? ''] = price;
    }
    final grouped = <String, List<Map<String, String>>>{};
    for (final user in _users) {
      final comment = user['comment'] ?? '';
      final batchMatch = RegExp(r'NOVA-BATCH=([^|;,\s]+)').firstMatch(comment);
      if (batchMatch != null) grouped.putIfAbsent(batchMatch.group(1)!, () => []).add(user);
    }
    var active = 0, expired = 0, unused = 0;
    var revenue = 0.0;
    for (final user in _users) {
      final comment = user['comment'] ?? '';
      final disabled = user['disabled'] == 'true';
      final isExpired = _expired(user);
      final used = (user['uptime'] ?? '0s') != '0s' || (user['last-logged-out'] ?? '') != '' || (user['last-logged-in'] ?? '') != '';
      if (disabled || isExpired) { if (isExpired) expired++; }
      else if (!used) unused++;
      else active++;
      final fromComment = _price(_priceFromComment(comment));
      final fromProfile = profilePrices[user['profile'] ?? ''];
      final price = fromComment ?? fromProfile;
      if (price != null) revenue += price;
    }
    return Scaffold(
      backgroundColor: _salesBg,
      appBar: AppBar(backgroundColor: _salesBg, foregroundColor: Colors.white, title: const Text('تقرير المبيعات'),
        actions: [IconButton(onPressed: _loading || _deleting ? null : _load, icon: const Icon(Icons.refresh_rounded))]),
      body: _loading ? const Center(child: CircularProgressIndicator(color: _salesAccent)) : RefreshIndicator(
        color: _salesAccent, onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(13, 8, 13, 24), children: [
          if (_error != null) _panelMessage(_error!, _salesRed),
          Row(children: [
            Expanded(child: _metric('الكروت النشطة', active.toString(), _salesGreen, Icons.check_circle_outline)),
            const SizedBox(width: 8),
            Expanded(child: _metric('غير المستخدمة', unused.toString(), _salesAccent, Icons.confirmation_number_outlined)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _metric('المنتهية / المعطلة', expired.toString(), _salesRed, Icons.timer_off_outlined)),
            const SizedBox(width: 8),
            Expanded(child: _metric('إجمالي المبيعات المتوقع', revenue.toStringAsFixed(2), _salesGreen, Icons.payments_outlined)),
          ]),
          const SizedBox(height: 7),
          _panelMessage('الكروت المقروءة: ${_users.length} • حسابات PPPoE: ${_secrets.length} • الباقات ذات السعر المعروف: ${profilePrices.length}. القيمة تقديرية من NOVA-PRICE في comment أو سعر الباقة إن وُجد.', _salesMuted),
          const SizedBox(height: 14),
          const Text('دفعات الكروت (NOVA-BATCH)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 8),
          if (grouped.isEmpty) _panelMessage('لم يُعثر على تعليقات NOVA-BATCH. الدفعات القديمة قد لا تحمل معرّف دفعة.', _salesMuted)
          else ...grouped.entries.map((entry) {
            final rows = entry.value;
            final total = rows.fold<double>(0, (sum, row) => sum + (_price(_priceFromComment(row['comment'] ?? '')) ?? profilePrices[row['profile'] ?? ''] ?? 0));
            return Container(margin: const EdgeInsets.only(bottom: 9), padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _salesPanel, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white.withOpacity(.06))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.inventory_2_outlined, color: _salesAccent),
                  const SizedBox(width: 8),
                  Expanded(child: Text(entry.key, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontWeight: FontWeight.w800))),
                  Text('${rows.length} كرت', style: const TextStyle(color: _salesMuted, fontSize: 11)),
                ]),
                const SizedBox(height: 5),
                Text('قيمة الدفعة المتوقعة: ${total.toStringAsFixed(2)}', style: const TextStyle(color: _salesGreen, fontWeight: FontWeight.w700, fontSize: 12)),
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, child: OutlinedButton.icon(
                  onPressed: _deleting ? null : () => _deleteBatch(entry.key, rows),
                  icon: const Icon(Icons.delete_sweep_outlined), label: Text(_deleting ? 'جارٍ الحذف...' : 'حذف الدفعة كاملة'),
                  style: OutlinedButton.styleFrom(foregroundColor: _salesRed),
                )),
              ]),
            );
          }),
          const SizedBox(height: 12),
          const Text('حسابات PPPoE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 8),
          ..._secrets.take(100).map((secret) => Container(
            margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: _salesPanel, borderRadius: BorderRadius.circular(11)),
            child: Row(children: [
              const Icon(Icons.settings_ethernet, color: _salesMuted, size: 18), const SizedBox(width: 8),
              Expanded(child: Text(secret['name'] ?? '—', style: const TextStyle(color: Colors.white, fontSize: 12))),
              Text(secret['profile'] ?? 'default', style: const TextStyle(color: _salesMuted, fontSize: 10)),
              const SizedBox(width: 6),
              Text(secret['disabled'] == 'true' ? 'معطل' : 'موجود', style: TextStyle(color: secret['disabled'] == 'true' ? _salesRed : _salesGreen, fontSize: 10)),
            ]),
          )),
        ]),
      ),
    );
  }

  Widget _metric(String title, String value, Color color, IconData icon) => Container(
    padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: _salesPanel, borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withOpacity(.2))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 20), const SizedBox(height: 10),
      Text(title, style: const TextStyle(color: _salesMuted, fontSize: 10)),
      const SizedBox(height: 5), Text(value, style: TextStyle(color: color, fontSize: 22, fontWeight: FontWeight.w900)),
    ]),
  );

  Widget _panelMessage(String text, Color color) => Container(
    margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(color: _salesPanel, borderRadius: BorderRadius.circular(12)),
    child: Text(text, style: TextStyle(color: color, fontSize: 11, height: 1.45)),
  );
}
