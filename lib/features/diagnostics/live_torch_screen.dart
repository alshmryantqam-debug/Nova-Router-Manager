import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _torchBg = Color(0xFF080B12);
const Color _torchPanel = Color(0xFF111722);
const Color _torchAccent = Color(0xFF8B7CFF);
const Color _torchMuted = Color(0xFF8D9AB0);
const Color _torchRx = Color(0xFF43D9A3);
const Color _torchTx = Color(0xFF67B7FF);
const Color _torchDanger = Color(0xFFFF657A);

class LiveTorchScreen extends ConsumerStatefulWidget {
  const LiveTorchScreen({super.key});

  @override
  ConsumerState<LiveTorchScreen> createState() => _LiveTorchScreenState();
}

class _LiveTorchScreenState extends ConsumerState<LiveTorchScreen> {
  RouterOsClient? _client;
  StreamSubscription<Map<String, String>>? _subscription;
  Timer? _refreshTimer;
  Timer? _restartTimer;
  final Map<String, _TorchFlow> _batch = {};
  Map<String, _TorchFlow> _flows = {};
  List<String> _interfaces = [];
  String? _selectedInterface;
  final _srcFilter = TextEditingController();
  final _dstFilter = TextEditingController();
  String _protocol = 'all';
  bool _loadingInterfaces = true;
  bool _running = false;
  String? _error;
  int _generation = 0;
  DateTime? _lastUpdate;

  @override
  void initState() {
    super.initState();
    _client = ref.read(activeRouterClientProvider);
    _refreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_running || _batch.isEmpty) return;
      _publishBatch();
    });
    if (_client != null) {
      _loadInterfaces();
    } else {
      _loadingInterfaces = false;
      _error = 'لا يوجد راوتر متصل.';
    }
  }

  @override
  void dispose() {
    _generation++;
    _refreshTimer?.cancel();
    _restartTimer?.cancel();
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    _srcFilter.dispose();
    _dstFilter.dispose();
    super.dispose();
  }

  Future<void> _loadInterfaces() async {
    final client = _client;
    if (client == null) return;
    setState(() { _loadingInterfaces = true; _error = null; });
    try {
      final rows = await client.command('/interface/print',
        args: const <String, String>{'.proplist': 'name,type,disabled,running'});
      final names = rows
          .where((row) => row['name'] != null && row['disabled'] != 'true')
          .map((row) => row['name']!)
          .toSet()
          .toList()
        ..sort();
      if (!mounted) return;
      setState(() {
        _interfaces = names;
        if (_selectedInterface == null || !names.contains(_selectedInterface)) {
          _selectedInterface = names.isEmpty ? null : names.first;
        }
        _loadingInterfaces = false;
        if (names.isEmpty) _error = 'لم يُرجع الراوتر أي منفذ متاح.';
      });
    } catch (e) {
      if (mounted) setState(() { _loadingInterfaces = false; _error = _friendly(e); });
    }
  }

  String _friendly(Object error) => error.toString()
      .replaceFirst('RouterOsException: ', '')
      .replaceFirst('Exception: ', '');

  Map<String, String> _torchArgs() {
    final interfaceName = _selectedInterface;
    if (interfaceName == null || interfaceName.isEmpty) {
      throw StateError('اختر منفذ الشبكة أولاً.');
    }
    final args = <String, String>{'interface': interfaceName};
    final src = _srcFilter.text.trim();
    final dst = _dstFilter.text.trim();
    if (src.isNotEmpty) args['src-address'] = src;
    if (dst.isNotEmpty) args['dst-address'] = dst;
    if (_protocol != 'all') args['protocol'] = _protocol;
    return args;
  }

  void _startTorch() {
    if (_client == null) {
      setState(() => _error = 'لا يوجد اتصال بالراوتر.');
      return;
    }
    try {
      final args = _torchArgs();
      final generation = ++_generation;
      _restartTimer?.cancel();
      final previous = _subscription;
      _subscription = null;
      if (previous != null) unawaited(previous.cancel());
      setState(() {
        _running = true;
        _error = null;
        _flows = {};
        _batch.clear();
        _lastUpdate = null;
      });
      _openTorch(generation, args);
    } catch (e) {
      setState(() => _error = _friendly(e));
    }
  }

  void _openTorch(int generation, Map<String, String> args) {
    if (!mounted || !_running || generation != _generation) return;
    final client = _client;
    if (client == null) return;
    try {
      _subscription = client.monitorStream('/tool/torch', args: args).listen(
        (row) {
          if (!mounted || generation != _generation || !_running) return;
          final flow = _TorchFlow.fromMap(row);
          if (flow.srcAddress.isEmpty && flow.dstAddress.isEmpty) return;
          _batch[flow.key] = flow;
        },
        onError: (Object error, StackTrace stack) {
          if (!mounted || generation != _generation) return;
          _publishBatch();
          setState(() { _running = false; _error = 'توقف بث Torch: ${_friendly(error)}'; });
        },
        onDone: () {
          if (!mounted || generation != _generation) return;
          _publishBatch();
          if (!_running) return;
          // Re-issue finite Torch responses on RouterOS builds that close each request.
          _restartTimer?.cancel();
          _restartTimer = Timer(const Duration(milliseconds: 500), () => _openTorch(generation, args));
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() { _running = false; _error = _friendly(e); });
      }
    }
  }

  void _publishBatch() {
    if (!mounted || _batch.isEmpty) return;
    final next = Map<String, _TorchFlow>.from(_batch);
    _batch.clear();
    setState(() {
      _flows = next;
      _lastUpdate = DateTime.now();
    });
  }

  Future<void> _stopTorch() async {
    _generation++;
    _restartTimer?.cancel();
    _restartTimer = null;
    final subscription = _subscription;
    _subscription = null;
    setState(() { _running = false; _batch.clear(); });
    if (subscription != null) {
      try { await subscription.cancel(); } catch (_) {}
    }
  }

  String _asIp(String raw) => raw.trim().split('/').first;

  bool _validIp(String raw) => InternetAddress.tryParse(_asIp(raw)) != null;

  Future<void> _blockAddress(String address, {required bool source}) async {
    final ip = _asIp(address);
    if (!_validIp(ip)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('عنوان IP غير صالح أو غير متاح في هذه السجّلة.')));
      return;
    }
    final isV6 = ip.contains(':');
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _torchPanel,
        title: Text('حظر $ip', style: const TextStyle(color: Colors.white)),
        content: const Text('اختر مكان إضافة قاعدة الإسقاط. سيتم تطبيقها مباشرة على الراوتر.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          OutlinedButton(onPressed: () => Navigator.pop(dialogContext, 'filter'), child: const Text('Filter')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, 'raw'), child: const Text('RAW')),
        ],
      ),
    );
    if (choice == null || _client == null) return;
    final path = isV6
        ? (choice == 'raw' ? '/ipv6/firewall/raw/add' : '/ipv6/firewall/filter/add')
        : (choice == 'raw' ? '/ip/firewall/raw/add' : '/ip/firewall/filter/add');
    await _executeAction('حظر $ip', () => _client!.command(path, args: <String, String>{
      'chain': choice == 'raw' ? 'prerouting' : 'forward',
      source ? 'src-address' : 'dst-address': ip,
      'action': 'drop',
      'comment': 'NOVA-TORCH-${DateTime.now().millisecondsSinceEpoch}',
    }));
  }

  Future<void> _limitAddress(String address) async {
    final ip = _asIp(address);
    if (!_validIp(ip)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('عنوان IP غير صالح أو غير متاح في هذه السجّلة.')));
      return;
    }
    final controller = TextEditingController(text: '5M/5M');
    final rate = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _torchPanel,
        title: Text('تحديد سرعة $ip', style: const TextStyle(color: Colors.white)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('صيغة Max-limit: رفع/تنزيل، مثل 5M/5M أو 512k/2M.', style: TextStyle(color: _torchMuted, fontSize: 12)),
          const SizedBox(height: 12),
          TextField(controller: controller, autofocus: true, style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
            decoration: const InputDecoration(labelText: 'Max-limit', hintText: '5M/5M')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('إنشاء Simple Queue')),
        ],
      ),
    );
    controller.dispose();
    if (rate == null || _client == null) return;
    if (!RegExp(r'^\d+(?:\.\d+)?[kKmMgGtT]?/\d+(?:\.\d+)?[kKmMgGtT]?$').hasMatch(rate)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('صيغة السرعة غير صحيحة. مثال: 5M/5M')));
      return;
    }
    final target = ip.contains(':') ? '$ip/128' : '$ip/32';
    final safeName = ip.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    await _executeAction('تحديد سرعة $ip', () => _client!.command('/queue/simple/add', args: <String, String>{
      'name': 'NOVA-TORCH-$safeName',
      'target': target,
      'max-limit': rate,
      'comment': 'NOVA live torch rate limit',
    }));
  }

  Future<void> _executeAction(String label, Future<List<Map<String, String>>> Function() action) async {
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('تم إرسال أمر: $label'),
        backgroundColor: const Color(0xFF176D58),
      ));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('فشل تنفيذ العملية: ${_friendly(e)}'),
        backgroundColor: const Color(0xFF9D3348),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null || !identical(client, _client)) {
      return const Scaffold(backgroundColor: _torchBg, body: Center(
        child: Text('اتصل بالراوتر أولاً ثم افتح Live Torch.', style: TextStyle(color: Colors.white))));
    }
    final ordered = _flows.values.toList()
      ..sort((a, b) => (b.rxMbps + b.txMbps).compareTo(a.rxMbps + a.txMbps));
    return Scaffold(
      backgroundColor: _torchBg,
      appBar: AppBar(
        backgroundColor: _torchBg,
        foregroundColor: Colors.white,
        title: const Text('Live Torch', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(tooltip: 'تحديث قائمة المنافذ', onPressed: _loadingInterfaces ? null : _loadInterfaces,
            icon: const Icon(Icons.refresh_rounded)),
        ],
      ),
      body: Column(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: _torchPanel, borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _torchAccent.withOpacity(.22))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 9, height: 9, decoration: BoxDecoration(
                color: _running ? _torchRx : _torchMuted, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(_running ? 'بث حي من /tool/torch' : 'مراقبة متوقفة',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
              Text(_lastUpdate == null ? '—' : TimeOfDay.fromDateTime(_lastUpdate!).format(context),
                style: const TextStyle(color: _torchMuted, fontSize: 11)),
            ]),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _selectedInterface,
              dropdownColor: _torchPanel,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Interface', prefixIcon: Icon(Icons.settings_ethernet)),
              items: _interfaces.map((name) => DropdownMenuItem(value: name, child: Text(name))).toList(),
              onChanged: _running || _loadingInterfaces ? null : (v) => setState(() => _selectedInterface = v),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: _srcFilter, enabled: !_running,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(labelText: 'src-address', hintText: '192.168.1.10'))),
              const SizedBox(width: 10),
              Expanded(child: TextField(controller: _dstFilter, enabled: !_running,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(labelText: 'dst-address', hintText: '8.8.8.8'))),
            ]),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _protocol,
              dropdownColor: _torchPanel,
              decoration: const InputDecoration(labelText: 'Protocol'),
              items: const [
                DropdownMenuItem(value: 'all', child: Text('كل البروتوكولات')),
                DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                DropdownMenuItem(value: 'udp', child: Text('UDP')),
                DropdownMenuItem(value: 'icmp', child: Text('ICMP')),
                DropdownMenuItem(value: 'ip', child: Text('IP')),
              ],
              onChanged: _running ? null : (v) => setState(() => _protocol = v ?? 'all'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: _torchDanger, fontSize: 12)),
            ],
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: FilledButton.icon(
                onPressed: _loadingInterfaces || _interfaces.isEmpty || _running ? null : _startTorch,
                icon: const Icon(Icons.play_arrow_rounded), label: const Text('بدء الفحص'))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(
                onPressed: _running ? _stopTorch : null,
                icon: const Icon(Icons.stop_rounded), label: const Text('إيقاف'))),
            ]),
          ]),
        ),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), child: Row(children: [
          Expanded(child: Text('التدفقات: ${ordered.length}', style: const TextStyle(color: _torchMuted, fontSize: 12))),
          Text('RX ↓ / TX ↑ • Mbps', style: TextStyle(color: _torchAccent, fontSize: 11, fontWeight: FontWeight.w700)),
        ])),
        Expanded(child: ordered.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(
              _running ? 'بانتظار بيانات Torch من الراوتر…' : 'ابدأ الفحص لعرض عناوين IP ومعدلات RX/TX.',
              textAlign: TextAlign.center, style: const TextStyle(color: _torchMuted))))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
              itemCount: ordered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 7),
              itemBuilder: (context, index) => _buildFlowCard(ordered[index]),
            )),
      ]),
    );
  }

  Widget _buildFlowCard(_TorchFlow flow) {
    final src = flow.srcAddress;
    final dst = flow.dstAddress;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: _torchPanel, borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFF273143))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.swap_horiz_rounded, color: _torchAccent),
          const SizedBox(width: 8),
          Expanded(child: Text(flow.protocol.isEmpty ? 'IP flow' : flow.protocol.toUpperCase(),
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
          if (flow.srcPort.isNotEmpty || flow.dstPort.isNotEmpty)
            Text('${flow.srcPort.isEmpty ? '—' : flow.srcPort} → ${flow.dstPort.isEmpty ? '—' : flow.dstPort}',
              style: const TextStyle(color: _torchMuted, fontSize: 11, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 8),
        _addressLine('SRC', src),
        _addressLine('DST', dst),
        const SizedBox(height: 9),
        Row(children: [
          Expanded(child: _rateDisplay('RX', flow.rxMbps, _torchRx)),
          Expanded(child: _rateDisplay('TX', flow.txMbps, _torchTx)),
        ]),
        const Divider(color: Color(0xFF283142), height: 18),
        Wrap(spacing: 6, runSpacing: 4, children: [
          OutlinedButton.icon(
            onPressed: _validIp(src) ? () => _blockAddress(src, source: true) : null,
            icon: const Icon(Icons.gpp_bad_outlined, size: 16),
            label: const Text('حظر المصدر'),
            style: OutlinedButton.styleFrom(foregroundColor: _torchDanger, visualDensity: VisualDensity.compact),
          ),
          OutlinedButton.icon(
            onPressed: _validIp(dst) ? () => _blockAddress(dst, source: false) : null,
            icon: const Icon(Icons.block_rounded, size: 16),
            label: const Text('حظر الوجهة'),
            style: OutlinedButton.styleFrom(foregroundColor: _torchDanger, visualDensity: VisualDensity.compact),
          ),
          FilledButton.tonalIcon(
            onPressed: _validIp(src) ? () => _limitAddress(src) : null,
            icon: const Icon(Icons.speed_rounded, size: 16),
            label: const Text('تحديد سرعة المصدر'),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ]),
      ]),
    );
  }

  Widget _addressLine(String label, String address) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [
      SizedBox(width: 38, child: Text(label, style: const TextStyle(color: _torchMuted, fontSize: 10, fontWeight: FontWeight.w800))),
      Expanded(child: SelectableText(address.isEmpty ? '—' : address,
        style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12))),
    ]),
  );

  Widget _rateDisplay(String label, double value, Color color) => Row(children: [
    Icon(label == 'RX' ? Icons.south_west_rounded : Icons.north_east_rounded, color: color, size: 17),
    const SizedBox(width: 5),
    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: _torchMuted, fontSize: 10)),
      Text(value.toStringAsFixed(3), style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w800)),
      const Text('Mbps', style: TextStyle(color: _torchMuted, fontSize: 9)),
    ]),
  ]);
}

class _TorchFlow {
  const _TorchFlow({
    required this.srcAddress,
    required this.dstAddress,
    required this.protocol,
    required this.srcPort,
    required this.dstPort,
    required this.rxMbps,
    required this.txMbps,
  });

  final String srcAddress;
  final String dstAddress;
  final String protocol;
  final String srcPort;
  final String dstPort;
  final double rxMbps;
  final double txMbps;

  String get key => '$srcAddress|$dstAddress|$protocol|$srcPort|$dstPort';

  factory _TorchFlow.fromMap(Map<String, String> row) => _TorchFlow(
    srcAddress: row['src-address'] ?? row['src-address6'] ?? row['src'] ?? '',
    dstAddress: row['dst-address'] ?? row['dst-address6'] ?? row['dst'] ?? '',
    protocol: row['protocol'] ?? row['ip-protocol'] ?? '',
    srcPort: row['src-port'] ?? '',
    dstPort: row['dst-port'] ?? '',
    rxMbps: _rateMbps(row['rx-rate'] ?? row['rx'] ?? row['rx-bits-per-second'] ?? '0'),
    txMbps: _rateMbps(row['tx-rate'] ?? row['tx'] ?? row['tx-bits-per-second'] ?? '0'),
  );
}

double _rateMbps(String raw) {
  final value = raw.trim().toLowerCase().replaceAll(' ', '');
  final match = RegExp(r'^([0-9]+(?:\.[0-9]+)?)\s*(k|m|g|t)?(?:bps|bit/s|bits/s|b/s)?$').firstMatch(value);
  if (match == null) return double.tryParse(value.replaceAll(',', '')) ?? 0;
  final amount = double.tryParse(match.group(1) ?? '') ?? 0;
  final multiplier = switch (match.group(2)) {
    'k' => 1e3,
    'm' => 1e6,
    'g' => 1e9,
    't' => 1e12,
    _ => 1.0,
  };
  return amount * multiplier / 1e6;
}
