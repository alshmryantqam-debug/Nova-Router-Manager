import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _nPanel = Color(0xFF111722);
const Color _nMuted = Color(0xFF8D9AB0);
const Color _nAccent = Color(0xFF8B7CFF);
const Color _nGreen = Color(0xFF43D9A3);
const Color _nRed = Color(0xFFFF657A);
const Color _nAmber = Color(0xFFFFB45E);

class NetworkToolsScreen extends ConsumerWidget {
  const NetworkToolsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Center(child: Text('اتصل براوتر أولًا.'));
    return NetworkToolsWorkspace(client: client);
  }
}

class NetworkToolsWorkspace extends StatelessWidget {
  const NetworkToolsWorkspace({super.key, required this.client});
  final RouterOsClient client;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Column(children: [
          Container(
            color: const Color(0xFF080B12),
            child: const TabBar(
              isScrollable: true,
              indicatorColor: _nAccent,
              labelColor: Colors.white,
              unselectedLabelColor: _nMuted,
              tabs: [
                Tab(icon: Icon(Icons.alt_route_rounded, size: 18), text: 'WAN & Routes Monitor'),
                Tab(icon: Icon(Icons.security_rounded, size: 18), text: 'Firewall'),
                Tab(icon: Icon(Icons.network_ping_rounded, size: 18), text: 'Ping & Logs'),
              ],
            ),
          ),
          Expanded(child: TabBarView(children: [
            _RoutesTab(client: client),
            _FirewallTab(client: client),
            _PingLogsTab(client: client),
          ])),
        ]),
      );
}

class _RouteEntry {
  const _RouteEntry({
    required this.id,
    required this.destination,
    required this.gateway,
    required this.table,
    required this.distance,
    required this.active,
    required this.disabled,
    required this.unreachable,
    required this.dynamic,
    required this.comment,
  });

  final String id;
  final String destination;
  final String gateway;
  final String table;
  final String distance;
  final bool active;
  final bool disabled;
  final bool unreachable;
  final bool dynamic;
  final String comment;

  factory _RouteEntry.fromMap(Map<String, String> row) {
    final flags = row['flags'] ?? '';
    final disabled = row['disabled'] == 'true' || flags.contains('X');
    final active = row['active'] == 'true' || flags.contains('A');
    final unreachable = row['unreachable'] == 'true' || (!active && !disabled);
    return _RouteEntry(
      id: row['.id'] ?? '',
      destination: row['dst-address'] ?? '0.0.0.0/0',
      gateway: row['gateway'] ?? row['immediate-gw'] ?? '—',
      table: row['routing-table'] ?? row['routing-mark'] ?? 'main',
      distance: row['distance'] ?? '—',
      active: active,
      disabled: disabled,
      unreachable: unreachable,
      dynamic: flags.contains('D') || flags.contains('C') || row['dynamic'] == 'true',
      comment: row['comment'] ?? '',
    );
  }
}

class _RoutesTab extends StatefulWidget {
  const _RoutesTab({required this.client});
  final RouterOsClient client;

  @override
  State<_RoutesTab> createState() => _RoutesTabState();
}

class _RoutesTabState extends State<_RoutesTab> {
  List<_RouteEntry> _routes = <_RouteEntry>[];
  bool _loading = true;
  bool _reading = false;
  String? _error;
  Timer? _timer;
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && !_reading) unawaited(_load(silent: true));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_reading) return;
    _reading = true;
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command(
        '/ip/route/print',
        args: const <String, String>{'.proplist': '.id,dst-address,gateway,immediate-gw,routing-table,distance,active,disabled,unreachable,flags,comment,dynamic'},
      );
      final routes = rows.map(_RouteEntry.fromMap).toList(growable: false)
        ..sort((a, b) {
          final byDestination = a.destination.compareTo(b.destination);
          return byDestination != 0 ? byDestination : a.distance.compareTo(b.distance);
        });
      if (!mounted) return;
      setState(() { _routes = routes; _loading = false; _error = null; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = _friendly(error); });
    } finally {
      _reading = false;
    }
  }

  Future<void> _toggle(_RouteEntry route) async {
    if (route.id.isEmpty || route.dynamic || _busy.contains(route.id)) return;
    setState(() => _busy.add(route.id));
    try {
      await widget.client.command('/ip/route/set', args: <String, String>{
        '.id': route.id,
        'disabled': route.disabled ? 'no' : 'yes',
      });
      if (!mounted) return;
      _show(route.disabled ? 'تم تفعيل المسار' : 'تم تعطيل المسار');
      await _load();
    } catch (error) {
      if (mounted) _show('تعذر تغيير حالة المسار: ' + _friendly(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy.remove(route.id));
    }
  }

  void _show(String text, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text), backgroundColor: isError ? _nRed.withOpacity(0.95) : const Color(0xFF202839)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _routes.isEmpty) return const Center(child: CircularProgressIndicator(color: _nAccent));
    if (_error != null && _routes.isEmpty) return _NetworkMessage(title: 'تعذر قراءة المسارات', message: _error!, onRetry: () => _load());
    final activeCount = _routes.where((route) => route.active && !route.disabled).length;
    return RefreshIndicator(
      color: _nAccent,
      backgroundColor: _nPanel,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 26),
        children: [
          _NetworkHeader(
            title: 'WAN & Routes Monitor',
            subtitle: 'قراءة مباشرة من /ip/route/print · تحديث كل 5 ثوانٍ',
            count: _routes.length,
            onRefresh: _load,
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _NetworkMetric(label: 'مسارات Active', value: activeCount.toString(), color: _nGreen)),
            const SizedBox(width: 8),
            Expanded(child: _NetworkMetric(label: 'Inactive / unreachable', value: _routes.where((r) => r.unreachable && !r.disabled).length.toString(), color: _nRed)),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text('تعذر تحديث الحالة: ' + _error!, style: const TextStyle(color: _nRed, fontSize: 11)),
          ],
          const SizedBox(height: 12),
          if (_routes.isEmpty)
            const _NetworkMessage(title: 'لم يُرجع الراوتر مسارات', message: 'تحقق من صلاحيات API أو إعدادات IP Routes.')
          else
            ..._routes.map((route) {
              final statusColor = route.disabled ? _nMuted : (route.active ? _nGreen : _nRed);
              final status = route.disabled ? 'Disabled' : (route.active ? 'Active' : 'Unreachable / Inactive');
              return Container(
                margin: const EdgeInsets.only(bottom: 9),
                decoration: BoxDecoration(color: _nPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: route.unreachable && !route.disabled ? _nRed.withOpacity(0.4) : Colors.white.withOpacity(0.055))),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(route.active ? Icons.check_circle_rounded : Icons.warning_rounded, color: statusColor, size: 21),
                      const SizedBox(width: 9),
                      Expanded(child: Text(route.destination, textDirection: TextDirection.ltr, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900))),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(color: statusColor.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                        child: Text(status, style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.w900)),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Wrap(spacing: 7, runSpacing: 7, children: [
                      _NetworkPill(label: 'Gateway: ' + route.gateway, direction: TextDirection.ltr),
                      _NetworkPill(label: 'Table: ' + route.table),
                      _NetworkPill(label: 'Distance: ' + route.distance),
                    ]),
                    if (route.comment.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(route.comment, style: const TextStyle(color: _nMuted, fontSize: 10)),
                    ],
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: route.dynamic || route.id.isEmpty || _busy.contains(route.id) ? null : () => _toggle(route),
                        icon: _busy.contains(route.id)
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(route.disabled ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 17),
                        label: Text(route.dynamic ? 'Dynamic route (للقراءة فقط)' : (route.disabled ? 'تفعيل المسار' : 'تعطيل المسار')),
                        style: OutlinedButton.styleFrom(foregroundColor: route.disabled ? _nGreen : _nAmber),
                      ),
                    ),
                  ]),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _FirewallTab extends StatelessWidget {
  const _FirewallTab({required this.client});
  final RouterOsClient client;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Column(children: [
          Container(
            color: const Color(0xFF080B12),
            child: const TabBar(
              isScrollable: true,
              indicatorColor: _nAccent,
              labelColor: Colors.white,
              unselectedLabelColor: _nMuted,
              tabs: [
                Tab(text: 'Filter'),
                Tab(text: 'Mangle'),
                Tab(text: 'RAW'),
              ],
            ),
          ),
          Expanded(child: TabBarView(children: [
            _FirewallRulesList(client: client, section: 'filter', title: 'Filter Rules'),
            _FirewallRulesList(client: client, section: 'mangle', title: 'Mangle Rules'),
            _FirewallRulesList(client: client, section: 'raw', title: 'RAW Rules'),
          ])),
        ]),
      );
}

class _FirewallRule {
  const _FirewallRule({
    required this.id,
    required this.chain,
    required this.action,
    required this.comment,
    required this.src,
    required this.dst,
    required this.protocol,
    required this.disabled,
    required this.bytes,
    required this.packets,
    required this.dynamic,
  });

  final String id;
  final String chain;
  final String action;
  final String comment;
  final String src;
  final String dst;
  final String protocol;
  final bool disabled;
  final int bytes;
  final int packets;
  final bool dynamic;

  factory _FirewallRule.fromMap(Map<String, String> row) {
    final flags = row['flags'] ?? '';
    return _FirewallRule(
      id: row['.id'] ?? '',
      chain: row['chain'] ?? '—',
      action: row['action'] ?? '—',
      comment: row['comment'] ?? '',
      src: row['src-address'] ?? '',
      dst: row['dst-address'] ?? '',
      protocol: row['protocol'] ?? '',
      disabled: row['disabled'] == 'true' || flags.contains('X'),
      bytes: int.tryParse(row['bytes'] ?? '') ?? 0,
      packets: int.tryParse(row['packets'] ?? '') ?? 0,
      dynamic: flags.contains('D') || row['dynamic'] == 'true',
    );
  }
}

class _FirewallRulesList extends StatefulWidget {
  const _FirewallRulesList({required this.client, required this.section, required this.title});
  final RouterOsClient client;
  final String section;
  final String title;

  @override
  State<_FirewallRulesList> createState() => _FirewallRulesListState();
}

class _FirewallRulesListState extends State<_FirewallRulesList> {
  List<_FirewallRule> _rules = <_FirewallRule>[];
  bool _loading = true;
  String? _error;
  bool _busyLoading = false;
  final Set<String> _busy = <String>{};

  String get _base => '/ip/firewall/' + widget.section;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_busyLoading) return;
    _busyLoading = true;
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command(
        _base + '/print',
        args: const <String, String>{
          'stats': '',
          '.proplist': '.id,chain,action,comment,src-address,dst-address,protocol,disabled,bytes,packets,flags,dynamic',
        },
      );
      final rules = rows.map(_FirewallRule.fromMap).toList(growable: false);
      if (!mounted) return;
      setState(() { _rules = rules; _loading = false; _error = null; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = _friendly(error); });
    } finally {
      _busyLoading = false;
    }
  }

  Future<void> _toggle(_FirewallRule rule) async {
    if (rule.id.isEmpty || rule.dynamic || _busy.contains(rule.id)) return;
    setState(() => _busy.add(rule.id));
    try {
      await widget.client.command(_base + '/set', args: <String, String>{
        '.id': rule.id,
        'disabled': rule.disabled ? 'no' : 'yes',
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(rule.disabled ? 'تم تفعيل القاعدة' : 'تم تعطيل القاعدة')));
      await _load();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تغيير القاعدة: ' + _friendly(error)), backgroundColor: _nRed));
    } finally {
      if (mounted) setState(() => _busy.remove(rule.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rules.isEmpty) return const Center(child: CircularProgressIndicator(color: _nAccent));
    if (_error != null && _rules.isEmpty) return _NetworkMessage(title: 'تعذر قراءة ' + widget.title, message: _error!, onRetry: () => _load());
    return RefreshIndicator(
      color: _nAccent,
      backgroundColor: _nPanel,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(_base + '/print stats', textDirection: TextDirection.ltr, style: const TextStyle(color: _nMuted, fontSize: 9)),
            ])),
            Text(_rules.length.toString(), style: const TextStyle(color: _nGreen, fontSize: 22, fontWeight: FontWeight.w900)),
            IconButton(onPressed: _load, tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded, color: _nAccent)),
          ]),
          const SizedBox(height: 8),
          if (_error != null) Text(_error!, style: const TextStyle(color: _nRed, fontSize: 11)),
          if (_rules.isEmpty)
            const _NetworkMessage(title: 'لا توجد قواعد للعرض', message: 'تحقق من وجود قواعد وصلاحية القراءة في الحساب الحالي.')
          else
            ..._rules.asMap().entries.map((entry) {
              final index = entry.key + 1;
              final rule = entry.value;
              final stateColor = rule.disabled ? _nMuted : _nGreen;
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(color: _nPanel, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white.withOpacity(0.055))),
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        width: 30,
                        height: 30,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: stateColor.withOpacity(0.12), borderRadius: BorderRadius.circular(9)),
                        child: Text(index.toString(), style: TextStyle(color: stateColor, fontSize: 11, fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(rule.comment.isEmpty ? rule.chain + ' → ' + rule.action : rule.comment, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Text(rule.chain + ' · ' + rule.action + (rule.protocol.isEmpty ? '' : ' · ' + rule.protocol), style: const TextStyle(color: _nMuted, fontSize: 9)),
                      ])),
                      IconButton(
                        tooltip: rule.disabled ? 'تفعيل القاعدة' : 'تعطيل القاعدة',
                        onPressed: rule.dynamic || rule.id.isEmpty || _busy.contains(rule.id) ? null : () => _toggle(rule),
                        icon: _busy.contains(rule.id)
                            ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(rule.disabled ? Icons.play_circle_outline_rounded : Icons.pause_circle_outline_rounded, color: rule.disabled ? _nGreen : _nRed),
                      ),
                    ]),
                    const SizedBox(height: 9),
                    Wrap(spacing: 7, runSpacing: 6, children: [
                      _NetworkPill(label: 'Bytes: ' + _compact(rule.bytes)),
                      _NetworkPill(label: 'Packets: ' + _compact(rule.packets)),
                      if (rule.src.isNotEmpty) _NetworkPill(label: 'Src: ' + rule.src, direction: TextDirection.ltr),
                      if (rule.dst.isNotEmpty) _NetworkPill(label: 'Dst: ' + rule.dst, direction: TextDirection.ltr),
                      _NetworkPill(label: rule.disabled ? 'Disabled' : 'Enabled'),
                    ]),
                    if (rule.dynamic)
                      const Padding(padding: EdgeInsets.only(top: 6), child: Text('قاعدة ديناميكية للقراءة فقط', style: TextStyle(color: _nMuted, fontSize: 9))),
                  ]),
                ),
              );
            }),
        ],
      ),
    );
  }
}

class _PingLogsTab extends StatefulWidget {
  const _PingLogsTab({required this.client});
  final RouterOsClient client;

  @override
  State<_PingLogsTab> createState() => _PingLogsTabState();
}

class _PingLogsTabState extends State<_PingLogsTab> {
  final TextEditingController _host = TextEditingController(text: '1.1.1.1');
  List<Map<String, String>> _pingRows = <Map<String, String>>[];
  List<Map<String, String>> _logs = <Map<String, String>>[];
  bool _pinging = false;
  bool _loadingLogs = true;
  String? _pingError;
  String? _logError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLogs());
  }

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _ping() async {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _pingError = 'أدخل عنوان IP أو اسم نطاق.');
      return;
    }
    setState(() { _pinging = true; _pingError = null; _pingRows = <Map<String, String>>[]; });
    try {
      final rows = await widget.client.command(
        '/ping',
        args: <String, String>{'address': host, 'count': '5', 'interval': '300ms'},
        timeout: const Duration(seconds: 20),
      );
      if (!mounted) return;
      setState(() => _pingRows = rows.reversed.toList(growable: false));
      if (rows.isEmpty) setState(() => _pingError = 'لم تُرجع أداة Ping نتائج؛ تحقق من صلاحيات الراوتر والوجهة.');
    } catch (error) {
      if (mounted) setState(() => _pingError = _friendly(error));
    } finally {
      if (mounted) setState(() => _pinging = false);
    }
  }

  Future<void> _loadLogs() async {
    if (mounted) setState(() { _loadingLogs = true; _logError = null; });
    try {
      final rows = await widget.client.command(
        '/log/print',
        args: const <String, String>{'.proplist': 'time,topics,message'},
      );
      final newestFirst = rows.reversed.take(100).toList(growable: false);
      if (!mounted) return;
      setState(() { _logs = newestFirst; _loadingLogs = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _logError = _friendly(error); _loadingLogs = false; });
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        color: _nAccent,
        backgroundColor: _nPanel,
        onRefresh: _loadLogs,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 26),
          children: [
            _NetworkHeader(
              title: 'Ping & Logs',
              subtitle: 'الاختبار والسجلات ينفذان من داخل الراوتر',
              count: _logs.length,
              onRefresh: _loadLogs,
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: _nPanel, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white.withOpacity(0.055))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('اختبار Ping من RouterOS', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900)),
                const SizedBox(height: 5),
                const Text('الأمر: /ping · عدد الحزم: 5 · الفاصل: 300ms', style: TextStyle(color: _nMuted, fontSize: 10)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _host,
                      textDirection: TextDirection.ltr,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(labelText: 'Host / IP', hintText: '1.1.1.1'),
                      onSubmitted: (_) => _ping(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _pinging ? null : _ping,
                    child: _pinging ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow_rounded),
                  ),
                ]),
                if (_pingError != null) ...[
                  const SizedBox(height: 8),
                  Text(_pingError!, style: const TextStyle(color: _nRed, fontSize: 11)),
                ],
                if (_pingRows.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  ..._pingRows.map((row) {
                    final failed = (row['status'] ?? '').isNotEmpty || (row['time'] ?? '').isEmpty;
                    final color = failed ? _nRed : _nGreen;
                    final summary = <String>[
                      if (row['seq'] != null) 'seq ' + row['seq']!,
                      if (row['time'] != null && row['time']!.isNotEmpty) row['time']!,
                      if (row['ttl'] != null && row['ttl']!.isNotEmpty) 'TTL ' + row['ttl']!,
                      if (row['status'] != null && row['status']!.isNotEmpty) row['status']!,
                    ];
                    return Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Row(children: [
                        Icon(failed ? Icons.close_rounded : Icons.check_rounded, size: 16, color: color),
                        const SizedBox(width: 7),
                        Expanded(child: Text(summary.isEmpty ? row.toString() : summary.join(' · '), style: TextStyle(color: color, fontSize: 11))),
                      ]),
                    );
                  }),
                ],
              ]),
            ),
            const SizedBox(height: 14),
            Row(children: [
              const Expanded(child: Text('آخر السجلات', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900))),
              IconButton(onPressed: _loadLogs, tooltip: 'تحديث السجلات', icon: const Icon(Icons.refresh_rounded, color: _nAccent)),
            ]),
            Text('/log/print · آخر 100 سجل', textDirection: TextDirection.ltr, style: const TextStyle(color: _nMuted, fontSize: 9)),
            const SizedBox(height: 8),
            if (_loadingLogs && _logs.isEmpty)
              const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: _nAccent)))
            else if (_logError != null && _logs.isEmpty)
              _NetworkMessage(title: 'تعذر تحميل السجلات', message: _logError!, onRetry: () => _loadLogs())
            else if (_logs.isEmpty)
              const _NetworkMessage(title: 'لا توجد سجلات', message: 'لم يرجع الراوتر أي سجلات.')
            else
              ..._logs.map((row) {
                final topics = row['topics'] ?? '';
                final message = row['message'] ?? '';
                final combined = (topics + ' ' + message).toLowerCase();
                final isError = combined.contains('error') || combined.contains('critical') || combined.contains('failure');
                final isWarning = combined.contains('warning');
                final color = isError ? _nRed : (isWarning ? _nAmber : _nMuted);
                return Container(
                  margin: const EdgeInsets.only(bottom: 7),
                  decoration: BoxDecoration(color: _nPanel, borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(isError || isWarning ? 0.24 : 0.06))),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(isError ? Icons.error_outline_rounded : (isWarning ? Icons.warning_amber_rounded : Icons.notes_rounded), size: 17, color: color),
                      const SizedBox(width: 8),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(spacing: 6, runSpacing: 3, children: [
                          if ((row['time'] ?? '').isNotEmpty) Text(row['time']!, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w800)),
                          Text(topics, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w800)),
                        ]),
                        const SizedBox(height: 4),
                        Text(message.isEmpty ? '—' : message, style: const TextStyle(color: Colors.white, fontSize: 10, height: 1.4)),
                      ])),
                    ]),
                  ),
                );
              }),
          ],
        ),
      );
}

class _NetworkHeader extends StatelessWidget {
  const _NetworkHeader({required this.title, required this.subtitle, required this.count, required this.onRefresh});
  final String title;
  final String subtitle;
  final int count;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF292647), Color(0xFF111722)]), borderRadius: BorderRadius.circular(17), border: Border.all(color: _nAccent.withOpacity(0.22))),
        child: Row(children: [
          const Icon(Icons.hub_rounded, color: _nAccent, size: 25),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: _nMuted, fontSize: 10)),
          ])),
          Text(count.toString(), style: const TextStyle(color: _nGreen, fontSize: 22, fontWeight: FontWeight.w900)),
          IconButton(onPressed: onRefresh, tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded, color: _nAccent)),
        ]),
      );
}

class _NetworkMetric extends StatelessWidget {
  const _NetworkMetric({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: _nPanel, borderRadius: BorderRadius.circular(13)),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(color: _nMuted, fontSize: 10))),
          Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w900)),
        ]),
      );
}

class _NetworkPill extends StatelessWidget {
  const _NetworkPill({required this.label, this.direction = TextDirection.ltr});
  final String label;
  final TextDirection direction;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(9)),
        child: Text(label, textDirection: direction, style: const TextStyle(color: _nMuted, fontSize: 9)),
      );
}

class _NetworkMessage extends StatelessWidget {
  const _NetworkMessage({required this.title, required this.message, this.onRetry});
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(23),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.hub_rounded, color: _nAccent, size: 37),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _nMuted, fontSize: 11, height: 1.5)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('إعادة المحاولة')),
            ],
          ]),
        ),
      );
}

String _compact(int value) {
  if (value >= 1000000000) return (value / 1000000000).toStringAsFixed(1) + 'G';
  if (value >= 1000000) return (value / 1000000).toStringAsFixed(1) + 'M';
  if (value >= 1000) return (value / 1000).toStringAsFixed(1) + 'K';
  return value.toString();
}

String _friendly(Object error) {
  if (error is TimeoutException) return 'انتهت مهلة الاتصال بالراوتر.';
  if (error is RouterOsException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
