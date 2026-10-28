import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';
import 'pppoe_pro_service.dart';

const Color _ppBg = Color(0xFF080B12);
const Color _ppPanel = Color(0xFF111722);
const Color _ppMuted = Color(0xFF8D9AB0);
const Color _ppAccent = Color(0xFF8B7CFF);
const Color _ppGreen = Color(0xFF43D9A3);
const Color _ppRed = Color(0xFFFF657A);

enum _SubscriberFilter { all, online, offline, expired, locked }

class PppoeScreen extends ConsumerWidget {
  const PppoeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Center(child: Text('اتصل براوتر أولًا.'));
    return PppoeWorkspace(client: client);
  }
}

class PppoeWorkspace extends StatefulWidget {
  const PppoeWorkspace({super.key, required this.client});
  final RouterOsClient client;

  @override
  State<PppoeWorkspace> createState() => _PppoeWorkspaceState();
}

class _PppoeWorkspaceState extends State<PppoeWorkspace> {
  late PppoeProService _service;
  List<PppoeSubscriber> _subscribers = [];
  List<String> _profiles = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  _SubscriberFilter _filter = _SubscriberFilter.all;
  Timer? _refreshTimer;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _service = PppoeProService(widget.client);
    unawaited(_load());
    _refreshTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted && !_loading) unawaited(_load(silent: true));
    });
  }

  @override
  void didUpdateWidget(covariant PppoeWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
      _service = PppoeProService(widget.client);
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait<Object>([
        _service.loadSubscribers(),
        _service.loadProfiles(),
      ]);
      if (!mounted) return;
      setState(() {
        _subscribers = results[0] as List<PppoeSubscriber>;
        _profiles = results[1] as List<String>;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = _friendly(error); });
      if (silent && _subscribers.isNotEmpty) _message('تعذر تحديث بيانات المشتركين: ${_friendly(error)}', isError: true);
    }
  }

  List<PppoeSubscriber> get _visible {
    final q = _query.trim().toLowerCase();
    return _subscribers.where((s) {
      final matchesQuery = q.isEmpty ||
          s.name.toLowerCase().contains(q) ||
          s.address.toLowerCase().contains(q) ||
          s.callerId.toLowerCase().contains(q) ||
          s.profile.toLowerCase().contains(q);
      final matchesFilter = switch (_filter) {
        _SubscriberFilter.all => true,
        _SubscriberFilter.online => s.online,
        _SubscriberFilter.offline => !s.online,
        _SubscriberFilter.expired => s.expired,
        _SubscriberFilter.locked => s.macLocked,
      };
      return matchesQuery && matchesFilter;
    }).toList(growable: false);
  }

  Future<void> _perform(PppoeSubscriber subscriber, String label, Future<void> Function() action) async {
    if (_busy.contains(subscriber.id)) return;
    setState(() => _busy.add(subscriber.id));
    try {
      await action();
      if (mounted) _message(label);
      await _load(silent: true);
    } catch (error) {
      if (mounted) _message(_friendly(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy.remove(subscriber.id));
    }
  }

  Future<String?> _chooseProfile({String? current, String title = 'اختيار الباقة', List<String>? options}) async {
    final available = (options ?? _profiles).isEmpty ? <String>['default'] : (options ?? _profiles);
    var selected = available.contains(current) ? current! : available.first;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: _ppPanel,
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: DropdownButtonFormField<String>(
            value: selected,
            isExpanded: true,
            items: available.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
            onChanged: (value) { if (value != null) setDialogState(() => selected = value); },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, selected), child: const Text('تطبيق')),
          ],
        ),
      ),
    );
  }

  Future<void> _changeProfile(PppoeSubscriber s) async {
    final next = await _chooseProfile(current: s.profile, title: 'تغيير باقة ${s.name}');
    if (next == null) return;
    await _perform(s, 'تم تغيير الباقة إلى $next', () => _service.changeProfile(s, next));
  }

  Future<void> _isolate(PppoeSubscriber s) async {
    final candidates = _profiles.where((p) => RegExp(r'(عزل|منته|expired|isolat|suspend|block)', caseSensitive: false).hasMatch(p)).toList();
    final options = candidates.isEmpty ? _profiles : candidates;
    if (options.isEmpty) {
      _message('لا توجد باقة عزل/انتهاء معرفة على الراوتر. أنشئ Profile مناسبًا أولًا.', isError: true);
      return;
    }
    final next = await _chooseProfile(current: options.first, title: 'تحويل ${s.name} إلى باقة العزل', options: options);
    if (next == null) return;
    await _perform(s, 'تم تحويل الحساب إلى $next', () => _service.setIsolationProfile(s, next));
  }

  Future<void> _speedDialog(PppoeSubscriber s) async {
    final upload = TextEditingController(text: _guessMbps(s.maxLimit, 0));
    final download = TextEditingController(text: _guessMbps(s.maxLimit, 1));
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<List<double>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _ppPanel,
        title: Text('تعديل السرعة اللحظية · ${s.name}', style: const TextStyle(color: Colors.white)),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('تعديل الطابور الديناميكي دون طرد جلسة PPPoE.', style: const TextStyle(color: _ppMuted, fontSize: 12)),
            const SizedBox(height: 10),
            TextFormField(controller: upload, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'رفع Upload (Mbps)'), validator: _validateSpeed),
            const SizedBox(height: 8),
            TextFormField(controller: download, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'تنزيل Download (Mbps)'), validator: _validateSpeed),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () {
            if (!(formKey.currentState?.validate() ?? false)) return;
            Navigator.pop(dialogContext, [double.parse(upload.text), double.parse(download.text)]);
          }, child: const Text('تطبيق فوري')),
        ],
      ),
    );
    upload.dispose();
    download.dispose();
    if (result == null) return;
    await _perform(s, 'تم تحديث السرعة دون فصل الجلسة', () => _service.setLiveSpeed(s, uploadMbps: result[0], downloadMbps: result[1]));
  }

  String? _validateSpeed(String? value) {
    final n = double.tryParse((value ?? '').trim());
    if (n == null || n <= 0 || n > 10000) return 'أدخل رقمًا بين 0.01 و10000';
    return null;
  }

  String _guessMbps(String limit, int index) {
    final pieces = limit.split('/');
    if (pieces.length <= index) return '10';
    final value = pieces[index].trim();
    final number = double.tryParse(value.replaceAll(RegExp(r'[^0-9.]'), ''));
    if (number == null || number <= 0) return '10';
    if (value.endsWith('G')) return (number * 1000).toString();
    if (value.endsWith('M')) return number.toString();
    if (value.endsWith('k')) return (number / 1000).toString();
    return (number / 1000000).toStringAsFixed(2);
  }

  Future<void> _ping(PppoeSubscriber s) async {
    try {
      final rows = await _service.ping(s.address);
      if (!mounted) return;
      final report = rows.isEmpty ? 'لم يرجع الراوتر نتائج Ping.' : rows.map((r) {
        final time = r['time'] ?? r['avg-rtt'] ?? '—';
        final ttl = r['ttl'] ?? '';
        final status = r['status'] ?? '';
        return [if (time.isNotEmpty) 'الزمن: $time', if (ttl.isNotEmpty) 'TTL: $ttl', if (status.isNotEmpty) status].join(' · ');
      }).join('\n');
      await showDialog<void>(context: context, builder: (dialogContext) => AlertDialog(
        backgroundColor: _ppPanel,
        title: Text('Ping · ${s.name} · ${s.address}', style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(child: SelectableText(report, style: const TextStyle(color: _ppGreen))),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إغلاق'))],
      ));
    } catch (error) {
      if (mounted) _message('فشل Ping: ${_friendly(error)}', isError: true);
    }
  }

  Future<void> _openSubscriber(PppoeSubscriber s) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _ppBg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => SafeArea(
        child: StatefulBuilder(builder: (context, setSheetState) {
          final busy = _busy.contains(s.id);
          Widget action(String title, IconData icon, VoidCallback? onTap, {Color color = _ppAccent}) => SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onTap,
              icon: Icon(icon, color: color, size: 18),
              label: Text(title),
              style: OutlinedButton.styleFrom(alignment: Alignment.centerRight, foregroundColor: Colors.white, side: BorderSide(color: color.withOpacity(.35)), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13)),
            ),
          );
          return Padding(
            padding: EdgeInsets.fromLTRB(18, 12, 18, MediaQuery.of(context).viewInsets.bottom + 20),
            child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: Container(width: 42, height: 4, decoration: BoxDecoration(color: _ppMuted.withOpacity(.5), borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 16),
              Row(children: [
                Icon(s.online ? Icons.wifi_rounded : Icons.wifi_off_rounded, color: s.online ? _ppGreen : _ppRed),
                const SizedBox(width: 10),
                Expanded(child: Text(s.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 19))),
                Text(s.online ? 'متصل' : 'Offline', style: TextStyle(color: s.online ? _ppGreen : _ppRed, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 12),
              _detailLine('IP الحالي', s.address.isEmpty ? '—' : s.address),
              _detailLine('Caller-ID / MAC', s.callerId.isEmpty ? 'غير مقفول' : s.callerId),
              _detailLine('الباقة', s.profile),
              _detailLine('السرعة الحالية RX / TX', '${s.rxMbps.toStringAsFixed(2)} / ${s.txMbps.toStringAsFixed(2)} Mbps'),
              _detailLine('استهلاك الجلسة RX / TX', '${_bytes(s.sessionRxBytes)} / ${_bytes(s.sessionTxBytes)}'),
              _detailLine('مدة الاتصال', s.uptime.isEmpty ? '—' : s.uptime),
              _detailLine('انتهاء الصلاحية', s.expiry == null ? 'غير محدد' : _date(s.expiry!)),
              _detailLine('آخر انقطاع', s.lastLoggedOut.isEmpty ? '—' : s.lastLoggedOut),
              _detailLine('سبب الانقطاع', s.lastDisconnectReason.isEmpty ? '—' : s.lastDisconnectReason),
              if (busy) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator(color: _ppAccent)),
              const SizedBox(height: 12),
              action('تغيير الباقة', Icons.layers_rounded, () { Navigator.pop(sheetContext); unawaited(_changeProfile(s)); }),
              action('تعديل السرعة اللحظية دون فصل', Icons.speed_rounded, () { Navigator.pop(sheetContext); unawaited(_speedDialog(s)); }),
              action(s.macLocked ? 'إعادة قفل Caller-ID الحالي' : 'قفل على الجهاز الحالي', Icons.lock_rounded, s.online && s.callerId.isNotEmpty ? () { Navigator.pop(sheetContext); unawaited(_perform(s, 'تم قفل الحساب على Caller-ID الحالي', () => _service.lockToCurrentDevice(s))); } : null, color: _ppGreen),
              action('فك قفل الماك (Reset Caller-ID)', Icons.lock_open_rounded, () { Navigator.pop(sheetContext); unawaited(_perform(s, 'تم مسح Caller-ID من الحساب', () => _service.resetCallerId(s))); }),
              action('طرد لإعادة الاتصال', Icons.power_settings_new_rounded, s.online ? () { Navigator.pop(sheetContext); unawaited(_perform(s, 'تم إرسال أمر فصل الجلسة', () => _service.disconnect(s))); } : null, color: _ppRed),
              action('فحص Ping مباشر', Icons.radar_rounded, s.address.isNotEmpty ? () { Navigator.pop(sheetContext); unawaited(_ping(s)); } : null),
              action('تجديد شهر بضغطة زر', Icons.event_available_rounded, () { Navigator.pop(sheetContext); unawaited(_perform(s, 'تم تجديد الصلاحية شهرًا', () => _service.renewOneMonth(s))); }, color: _ppGreen),
              action('تحويل لباقة العزل/الانتهاء', Icons.gpp_bad_rounded, () { Navigator.pop(sheetContext); unawaited(_isolate(s)); }, color: _ppRed),
              const SizedBox(height: 8),
            ])),
          );
        }),
      ),
    );
  }

  Widget _detailLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 145, child: Text(label, style: const TextStyle(color: _ppMuted, fontSize: 12))),
      Expanded(child: SelectableText(value, style: const TextStyle(color: Colors.white, fontSize: 12))),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final online = _subscribers.where((s) => s.online).length;
    final expired = _subscribers.where((s) => s.expired).length;
    final rows = _visible;
    if (_loading && _subscribers.isEmpty) return const Center(child: CircularProgressIndicator(color: _ppAccent));
    if (_error != null && _subscribers.isEmpty) return Center(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.cloud_off_rounded, color: _ppRed, size: 38),
        const SizedBox(height: 10),
        Text('تعذر تحميل مشتركي PPPoE\n$_error', textAlign: TextAlign.center),
        const SizedBox(height: 12),
        FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('إعادة المحاولة')),
      ]),
    ));
    return RefreshIndicator(
      color: _ppAccent,
      backgroundColor: _ppPanel,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 32),
        children: [
          Row(children: [
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('إدارة البرودباند', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
              SizedBox(height: 3),
              Text('لوحة موحّدة للمشتركين والجلسات والطوابير', style: TextStyle(color: _ppMuted, fontSize: 11)),
            ])),
            IconButton(onPressed: _load, icon: const Icon(Icons.refresh_rounded, color: _ppAccent), tooltip: 'تحديث'),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _stat('إجمالي', '${_subscribers.length}', _ppAccent)),
            const SizedBox(width: 8),
            Expanded(child: _stat('متصل الآن', '$online', _ppGreen)),
            const SizedBox(width: 8),
            Expanded(child: _stat('منتهي', '$expired', _ppRed)),
          ]),
          const SizedBox(height: 12),
          TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: 'بحث بالاسم أو IP أو MAC أو الباقة',
              filled: true,
              fillColor: _ppPanel,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              _filterChip('الكل', _SubscriberFilter.all),
              _filterChip('المتصلون الآن', _SubscriberFilter.online),
              _filterChip('المفصولون Offline', _SubscriberFilter.offline),
              _filterChip('منتهية الصلاحية', _SubscriberFilter.expired),
              _filterChip('المقفولون بالماك', _SubscriberFilter.locked),
            ]),
          ),
          const SizedBox(height: 8),
          if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('آخر تحديث لم يكتمل: $_error', style: const TextStyle(color: _ppRed, fontSize: 11))),
          if (rows.isEmpty)
            const Padding(padding: EdgeInsets.all(28), child: Text('لا يوجد مشتركون يطابقون البحث أو الفلتر.', textAlign: TextAlign.center, style: TextStyle(color: _ppMuted)))
          else
            ...rows.map(_subscriberCard),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _filterChip(String label, _SubscriberFilter value) => Padding(
    padding: const EdgeInsets.only(left: 7),
    child: ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: _filter == value,
      onSelected: (_) => setState(() => _filter = value),
      selectedColor: _ppAccent.withOpacity(.25),
      backgroundColor: _ppPanel,
      side: BorderSide(color: _filter == value ? _ppAccent : Colors.white10),
      labelStyle: TextStyle(color: _filter == value ? Colors.white : _ppMuted),
    ),
  );

  Widget _stat(String title, String value, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 12),
    decoration: BoxDecoration(color: _ppPanel, borderRadius: BorderRadius.circular(14), border: Border.all(color: color.withOpacity(.2))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: _ppMuted, fontSize: 10)),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(color: color, fontSize: 19, fontWeight: FontWeight.w900)),
    ]),
  );

  Widget _subscriberCard(PppoeSubscriber s) => Container(
    margin: const EdgeInsets.only(bottom: 9),
    decoration: BoxDecoration(color: _ppPanel, borderRadius: BorderRadius.circular(16), border: Border.all(color: (s.online ? _ppGreen : _ppRed).withOpacity(.22))),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _openSubscriber(s),
      child: Padding(
        padding: const EdgeInsets.all(13),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 39, height: 39, decoration: BoxDecoration(color: (s.online ? _ppGreen : _ppRed).withOpacity(.12), borderRadius: BorderRadius.circular(12)), child: Icon(s.online ? Icons.wifi_rounded : Icons.wifi_off_rounded, color: s.online ? _ppGreen : _ppRed)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
              const SizedBox(height: 3),
              Text('${s.profile} · ${s.address.isEmpty ? 'لا يوجد IP نشط' : s.address}', style: const TextStyle(color: _ppMuted, fontSize: 11)),
            ])),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(color: (s.online ? _ppGreen : _ppRed).withOpacity(.12), borderRadius: BorderRadius.circular(8)), child: Text(s.online ? 'ONLINE' : 'OFFLINE', style: TextStyle(color: s.online ? _ppGreen : _ppRed, fontWeight: FontWeight.w900, fontSize: 10))),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _metric('RX', '${s.rxMbps.toStringAsFixed(2)} Mbps', _ppGreen)),
            Expanded(child: _metric('TX', '${s.txMbps.toStringAsFixed(2)} Mbps', _ppAccent)),
            Expanded(child: _metric('جلسة RX/TX', '${_bytes(s.sessionRxBytes)} / ${_bytes(s.sessionTxBytes)}', Colors.white70)),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Icon(s.macLocked ? Icons.lock_rounded : Icons.lock_open_rounded, size: 14, color: s.macLocked ? _ppGreen : _ppMuted),
            const SizedBox(width: 5),
            Expanded(child: Text(s.callerId.isEmpty ? 'Caller-ID غير مقفول' : s.callerId, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _ppMuted, fontSize: 10))),
            if (s.expired) const Text('منتهي', style: TextStyle(color: _ppRed, fontSize: 10, fontWeight: FontWeight.bold)),
            const Icon(Icons.chevron_left_rounded, color: _ppMuted),
          ]),
        ]),
      ),
    ),
  );

  Widget _metric(String title, String value, Color color) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: const TextStyle(color: _ppMuted, fontSize: 9)),
    const SizedBox(height: 3),
    Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11)),
  ]);

  void _message(String value, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value), backgroundColor: isError ? _ppRed : const Color(0xFF202839)));
  }
}

String _bytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}

String _date(DateTime value) => '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';

String _friendly(Object error) {
  final value = error.toString().replaceFirst('RouterOsException: ', '');
  if (value.contains('SocketException') || value.contains('connection')) return 'تعذر الاتصال بالراوتر؛ تحقق من الاتصال والصلاحيات.';
  if (value.contains('TimeoutException') || value.contains('timed out')) return 'انتهت مهلة الطلب؛ حاول مجددًا.';
  return value;
}
