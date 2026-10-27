import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _ncPanel = Color(0xFF111722);
const Color _ncMuted = Color(0xFF8D9AB0);
const Color _ncAccent = Color(0xFF8B7CFF);
const Color _ncGreen = Color(0xFF43D9A3);
const Color _ncBlue = Color(0xFF67B7FF);
const Color _ncRed = Color(0xFFFF657A);

class NeighborsConnectionsScreen extends ConsumerWidget {
  const NeighborsConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Center(child: Text('اتصل براوتر أولًا.'));
    return NeighborsConnectionsWorkspace(client: client);
  }
}

class NeighborsConnectionsWorkspace extends StatefulWidget {
  const NeighborsConnectionsWorkspace({super.key, required this.client});
  final RouterOsClient client;

  @override
  State<NeighborsConnectionsWorkspace> createState() => _NeighborsConnectionsWorkspaceState();
}

class _NeighborsConnectionsWorkspaceState extends State<NeighborsConnectionsWorkspace> {
  List<_NeighborDevice> _neighbors = <_NeighborDevice>[];
  List<_FirewallConnection> _connections = <_FirewallConnection>[];
  bool _neighborsLoading = true;
  bool _connectionsLoading = true;
  bool _neighborsRefreshing = false;
  bool _connectionsRefreshing = false;
  String? _neighborsError;
  String? _connectionsError;
  String _neighborSearch = '';
  String _connectionSearch = '';
  Timer? _timer;
  final Set<String> _removing = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadNeighbors());
    unawaited(_loadConnections());
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      if (!_neighborsRefreshing) unawaited(_loadNeighbors(silent: true));
      if (!_connectionsRefreshing) unawaited(_loadConnections(silent: true));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadNeighbors({bool silent = false}) async {
    if (_neighborsRefreshing) return;
    _neighborsRefreshing = true;
    if (!silent && mounted) setState(() { _neighborsLoading = true; _neighborsError = null; });
    try {
      final rows = await widget.client.command(
        '/ip/neighbor/print',
        args: const <String, String>{
          '.proplist': 'identity,address,mac-address,platform,board,version,interface,age,uptime',
        },
      );
      final items = rows.map(_NeighborDevice.fromMap).where((item) =>
          item.identity.isNotEmpty || item.address.isNotEmpty || item.mac.isNotEmpty).toList(growable: false)
        ..sort((a, b) => a.identity.toLowerCase().compareTo(b.identity.toLowerCase()));
      if (!mounted) return;
      setState(() { _neighbors = items; _neighborsLoading = false; _neighborsError = null; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _neighborsLoading = false; _neighborsError = _friendly(error); });
    } finally {
      _neighborsRefreshing = false;
    }
  }

  Future<void> _loadConnections({bool silent = false}) async {
    if (_connectionsRefreshing) return;
    _connectionsRefreshing = true;
    if (!silent && mounted) setState(() { _connectionsLoading = true; _connectionsError = null; });
    try {
      final rows = await widget.client.command(
        '/ip/firewall/connection/print',
        args: const <String, String>{
          '.proplist': '.id,src-address,dst-address,protocol,orig-bytes,repl-bytes,orig-packets,repl-packets,src-port,dst-port,tcp-state,timeout,seen-reply,assured,confirmed,connection-mark',
        },
      );
      final items = rows.map(_FirewallConnection.fromMap)
          .where((item) => item.id.isNotEmpty || item.source.isNotEmpty || item.destination.isNotEmpty)
          .toList(growable: false);
      if (!mounted) return;
      setState(() { _connections = items; _connectionsLoading = false; _connectionsError = null; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _connectionsLoading = false; _connectionsError = _friendly(error); });
    } finally {
      _connectionsRefreshing = false;
    }
  }

  void _show(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? _ncRed.withOpacity(0.95) : const Color(0xFF202839),
    ));
  }

  Future<void> _removeEndedSessions() async {
    final ended = _connections.where((connection) => connection.isEndedTcp && connection.id.isNotEmpty).toList(growable: false);
    if (ended.isEmpty) {
      _show('لا توجد جلسات TCP منتهية معروفة للحذف.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _ncPanel,
        title: const Text('حذف الجلسات المنتهية؟', style: TextStyle(color: Colors.white)),
        content: Text(
          'سيتم إرسال طلب حذف لـ ' + ended.length.toString() +
          ' جلسة TCP بحالات إغلاق/انتظار نهائية فقط. لن تُحذف الجلسات النشطة أو جميع الاتصالات.',
          style: const TextStyle(color: _ncMuted, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _ncRed),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف المحدد فقط'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var succeeded = 0;
    var failed = 0;
    for (final connection in ended) {
      if (!mounted) return;
      setState(() => _removing.add(connection.id));
      try {
        await widget.client.command('/ip/firewall/connection/remove', args: <String, String>{'.id': connection.id});
        succeeded++;
      } catch (_) {
        failed++;
      } finally {
        if (mounted) setState(() => _removing.remove(connection.id));
      }
    }
    if (!mounted) return;
    _show('طلبات الحذف الناجحة: ' + succeeded.toString() + '، الفاشلة: ' + failed.toString(),
      isError: failed > 0);
    await _loadConnections();
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(children: [
      Container(
        margin: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          color: _ncPanel,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.white.withOpacity(0.06)),
        ),
        child: const TabBar(
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(color: Color(0xFF292647), borderRadius: BorderRadius.all(Radius.circular(11))),
          labelColor: Colors.white,
          unselectedLabelColor: _ncMuted,
          tabs: [
            Tab(icon: Icon(Icons.devices_other_rounded, size: 17), text: 'IP Neighbors / MNDP'),
            Tab(icon: Icon(Icons.swap_horiz_rounded, size: 17), text: 'Firewall Connections'),
          ],
        ),
      ),
      Expanded(child: TabBarView(children: [_buildNeighbors(), _buildConnections()])),
    ]),
  );

  Widget _buildNeighbors() {
    final query = _neighborSearch.trim().toLowerCase();
    final visible = _neighbors.where((item) => item.searchText.contains(query)).toList(growable: false);
    if (_neighborsLoading && _neighbors.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _ncAccent));
    }
    if (_neighborsError != null && _neighbors.isEmpty) {
      return _NeighborMessage(title: 'تعذر كشف الأجهزة', message: _neighborsError!, onRetry: _loadNeighbors);
    }
    return RefreshIndicator(
      color: _ncAccent,
      backgroundColor: _ncPanel,
      onRefresh: _loadNeighbors,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 5, 14, 28),
        children: [
          _HeaderCard(
            icon: Icons.radar_rounded,
            title: 'كاشف الأجهزة المتصلة',
            subtitle: 'قراءة IP Neighbors / MNDP من الراوتر كل 10 ثوانٍ',
            count: _neighbors.length.toString(),
          ),
          const SizedBox(height: 10),
          TextField(
            onChanged: (value) => setState(() => _neighborSearch = value),
            decoration: InputDecoration(
              hintText: 'بحث بالهوية أو IP أو MAC أو المنصة...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _neighborSearch.isEmpty ? null : IconButton(
                onPressed: () => setState(() => _neighborSearch = ''),
                icon: const Icon(Icons.close_rounded),
              ),
              filled: true,
              fillColor: _ncPanel,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
            ),
          ),
          if (_neighborsError != null) ...[
            const SizedBox(height: 8),
            Text('تعذّر تحديث آخر قراءة: ' + _neighborsError!, style: const TextStyle(color: _ncRed, fontSize: 11)),
          ],
          const SizedBox(height: 10),
          if (visible.isEmpty)
            _NeighborMessage(
              title: _neighbors.isEmpty ? 'لا توجد أجهزة ظاهرة' : 'لا توجد نتائج',
              message: _neighbors.isEmpty
                ? 'قد لا تعرض MNDP/LLDP أجهزة لا تعلن عن نفسها، أو قد تمنع إعدادات الواجهات اكتشافها.'
                : 'جرّب البحث بعنوان IP أو MAC أو الاسم.',
            )
          else
            ...visible.map((device) => Container(
              margin: const EdgeInsets.only(bottom: 9),
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: _ncPanel,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: Colors.white.withOpacity(0.055)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    width: 39,
                    height: 39,
                    decoration: BoxDecoration(color: _ncAccent.withOpacity(0.14), borderRadius: BorderRadius.circular(11)),
                    child: const Icon(Icons.router_rounded, color: _ncAccent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(device.identity.isEmpty ? 'جهاز بلا Identity' : device.identity,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 3),
                    Text(device.address.isEmpty ? 'IP غير معلن' : device.address,
                      textDirection: TextDirection.ltr, style: const TextStyle(color: _ncBlue, fontSize: 11)),
                  ])),
                ]),
                const Divider(height: 20, color: Color(0xFF283142)),
                _InfoLine(label: 'MAC address', value: device.mac),
                _InfoLine(label: 'Platform', value: device.platform),
                _InfoLine(label: 'Board', value: device.board),
                _InfoLine(label: 'Version', value: device.version),
                _InfoLine(label: 'Interface', value: device.interfaceName),
                if (device.age.isNotEmpty) _InfoLine(label: 'Age', value: device.age),
              ]),
            )),
          const SizedBox(height: 6),
          OutlinedButton.icon(onPressed: _neighborsRefreshing ? null : () => _loadNeighbors(),
            icon: const Icon(Icons.refresh_rounded), label: const Text('تحديث قائمة الأجهزة')),
        ],
      ),
    );
  }

  Widget _buildConnections() {
    final query = _connectionSearch.trim().toLowerCase();
    final visible = _connections.where((item) => item.searchText.contains(query)).toList(growable: false);
    final staleCount = _connections.where((item) => item.isEndedTcp && item.id.isNotEmpty).length;
    final sourceCounts = <String, int>{};
    for (final connection in _connections) {
      final source = connection.source.isEmpty ? 'غير معروف' : connection.source.split(':').first;
      sourceCounts[source] = (sourceCounts[source] ?? 0) + 1;
    }
    final topSource = sourceCounts.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final topLabel = topSource.isEmpty ? '—' : topSource.first.key + ' (' + topSource.first.value.toString() + ')';
    if (_connectionsLoading && _connections.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _ncAccent));
    }
    if (_connectionsError != null && _connections.isEmpty) {
      return _NeighborMessage(title: 'تعذر قراءة الاتصالات', message: _connectionsError!, onRetry: _loadConnections);
    }
    return RefreshIndicator(
      color: _ncAccent,
      backgroundColor: _ncPanel,
      onRefresh: _loadConnections,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 5, 14, 28),
        children: [
          _HeaderCard(
            icon: Icons.swap_horiz_rounded,
            title: 'مراقب الاتصالات النشطة',
            subtitle: 'عدادات bytes والحالات من Connection Tracking',
            count: _connections.length.toString(),
          ),
          const SizedBox(height: 9),
          Row(children: [
            Expanded(child: _SmallStat(label: 'أكثر مصدر جلسات', value: topLabel, color: _ncBlue)),
            const SizedBox(width: 8),
            Expanded(child: _SmallStat(label: 'TCP منتهية', value: staleCount.toString(), color: _ncRed)),
          ]),
          const SizedBox(height: 9),
          TextField(
            onChanged: (value) => setState(() => _connectionSearch = value),
            decoration: InputDecoration(
              hintText: 'بحث بالمصدر أو الوجهة أو البروتوكول...',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _connectionSearch.isEmpty ? null : IconButton(
                onPressed: () => setState(() => _connectionSearch = ''),
                icon: const Icon(Icons.close_rounded),
              ),
              filled: true,
              fillColor: _ncPanel,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 9),
          if (_connectionsError != null)
            Text('تعذّر تحديث آخر قراءة: ' + _connectionsError!, style: const TextStyle(color: _ncRed, fontSize: 11)),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: staleCount == 0 || _removing.isNotEmpty ? null : _removeEndedSessions,
              icon: _removing.isNotEmpty
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.cleaning_services_rounded),
              label: Text('حذف جلسات TCP المنتهية فقط (' + staleCount.toString() + ')'),
              style: FilledButton.styleFrom(foregroundColor: _ncRed),
            ),
          ),
          const SizedBox(height: 10),
          if (visible.isEmpty)
            _NeighborMessage(title: 'لا توجد اتصالات', message: 'لم تُرجع Connection Tracking أي صفوف مطابقة.')
          else
            ...visible.map((connection) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _ncPanel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: connection.isEndedTcp ? _ncRed.withOpacity(0.25) : Colors.white.withOpacity(0.055)),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    decoration: BoxDecoration(
                      color: (connection.isEndedTcp ? _ncRed : _ncBlue).withOpacity(0.13),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(connection.protocolLabel, style: TextStyle(
                      color: connection.isEndedTcp ? _ncRed : _ncBlue,
                      fontSize: 10, fontWeight: FontWeight.w900,
                    )),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(
                    connection.tcpState.isEmpty ? (connection.timeout.isEmpty ? 'الحالة غير متاحة' : 'Timeout: ' + connection.timeout)
                      : connection.tcpState + (connection.timeout.isEmpty ? '' : ' · ' + connection.timeout),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _ncMuted, fontSize: 10),
                  )),
                  if (_removing.contains(connection.id))
                    const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ]),
                const SizedBox(height: 9),
                _InfoLine(label: 'المصدر', value: connection.source),
                _InfoLine(label: 'الوجهة', value: connection.destination),
                _InfoLine(label: 'إجمالي البيانات', value: _bytesLabel(connection.totalBytes)),
                _InfoLine(label: 'الاتجاه الأصلي / الرد', value: _bytesLabel(connection.origBytes) + ' / ' + _bytesLabel(connection.replBytes)),
                if (connection.connectionMark.isNotEmpty) _InfoLine(label: 'Connection mark', value: connection.connectionMark),
              ]),
            )),
          const SizedBox(height: 6),
          OutlinedButton.icon(onPressed: _connectionsRefreshing ? null : () => _loadConnections(),
            icon: const Icon(Icons.refresh_rounded), label: const Text('تحديث الاتصالات')),
          const SizedBox(height: 6),
          const Text(
            'ملاحظة: عدد الجلسات لا يساوي استهلاك الباندويث. إجمالي bytes هو عداد اتصال؛ القياس اللحظي للسرعة يحتاج مراقبة الواجهات أو الطوابير.',
            style: TextStyle(color: _ncMuted, fontSize: 10, height: 1.45),
          ),
        ],
      ),
    );
  }
}

class _NeighborDevice {
  const _NeighborDevice({
    required this.identity,
    required this.address,
    required this.mac,
    required this.platform,
    required this.board,
    required this.version,
    required this.interfaceName,
    required this.age,
  });

  final String identity;
  final String address;
  final String mac;
  final String platform;
  final String board;
  final String version;
  final String interfaceName;
  final String age;

  String get searchText => <String>[identity, address, mac, platform, board, version, interfaceName].join(' ').toLowerCase();

  factory _NeighborDevice.fromMap(Map<String, String> row) => _NeighborDevice(
    identity: row['identity'] ?? '',
    address: row['address'] ?? '',
    mac: row['mac-address'] ?? '',
    platform: row['platform'] ?? '',
    board: row['board'] ?? '',
    version: row['version'] ?? '',
    interfaceName: row['interface'] ?? row['interface-name'] ?? '',
    age: row['age'] ?? row['uptime'] ?? '',
  );
}

class _FirewallConnection {
  const _FirewallConnection({
    required this.id,
    required this.source,
    required this.destination,
    required this.protocol,
    required this.bytes,
    required this.origBytes,
    required this.replBytes,
    required this.tcpState,
    required this.timeout,
    required this.connectionMark,
  });

  final String id;
  final String source;
  final String destination;
  final String protocol;
  final int bytes;
  final int origBytes;
  final int replBytes;
  final String tcpState;
  final String timeout;
  final String connectionMark;

  int get totalBytes => bytes > 0 ? bytes : origBytes + replBytes;
  String get protocolLabel {
    final normalized = protocol.toLowerCase();
    if (normalized == '6' || normalized == 'tcp') return 'TCP';
    if (normalized == '17' || normalized == 'udp') return 'UDP';
    if (normalized == '1' || normalized == 'icmp') return 'ICMP';
    return protocol.isEmpty ? 'غير معروف' : protocol;
  }

  bool get isEndedTcp {
    if (protocolLabel != 'TCP') return false;
    const states = <String>{'close', 'closed', 'time-wait', 'fin-wait', 'last-ack', 'closing'};
    return states.contains(tcpState.toLowerCase().trim());
  }

  String get searchText => <String>[source, destination, protocolLabel, tcpState, timeout, connectionMark].join(' ').toLowerCase();

  factory _FirewallConnection.fromMap(Map<String, String> row) {
    int read(String key) => int.tryParse(row[key] ?? '') ?? 0;
    return _FirewallConnection(
      id: row['.id'] ?? '',
      source: row['src-address'] ?? '',
      destination: row['dst-address'] ?? '',
      protocol: row['protocol'] ?? '',
      bytes: read('bytes'),
      origBytes: read('orig-bytes'),
      replBytes: read('repl-bytes'),
      tcpState: row['tcp-state'] ?? '',
      timeout: row['timeout'] ?? '',
      connectionMark: row['connection-mark'] ?? '',
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.icon, required this.title, required this.subtitle, required this.count});
  final IconData icon;
  final String title;
  final String subtitle;
  final String count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      gradient: const LinearGradient(colors: [Color(0xFF292647), Color(0xFF111722)]),
      borderRadius: BorderRadius.circular(17),
      border: Border.all(color: _ncAccent.withOpacity(0.22)),
    ),
    child: Row(children: [
      Icon(icon, color: _ncAccent, size: 27),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: _ncMuted, fontSize: 10)),
      ])),
      Text(count, style: const TextStyle(color: _ncGreen, fontSize: 22, fontWeight: FontWeight.w900)),
    ]),
  );
}

class _SmallStat extends StatelessWidget {
  const _SmallStat({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(color: _ncPanel, borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: _ncMuted, fontSize: 9)),
      const SizedBox(height: 4),
      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w900)),
    ]),
  );
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 114, child: Text(label, style: const TextStyle(color: _ncMuted, fontSize: 9))),
        const SizedBox(width: 5),
        Expanded(child: Text(value, textDirection: TextDirection.ltr, maxLines: 3, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white70, fontSize: 10))),
      ]),
    );
  }
}

class _NeighborMessage extends StatelessWidget {
  const _NeighborMessage({required this.title, required this.message, this.onRetry});
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.radar_rounded, color: _ncAccent, size: 38),
      const SizedBox(height: 12),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
      const SizedBox(height: 7),
      Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _ncMuted, fontSize: 12, height: 1.5)),
      if (onRetry != null) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('إعادة المحاولة')),
      ],
    ])),
  );
}

String _bytesLabel(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1) + ' GB';
  if (bytes >= 1024 * 1024) return (bytes / (1024 * 1024)).toStringAsFixed(1) + ' MB';
  if (bytes >= 1024) return (bytes / 1024).toStringAsFixed(1) + ' KB';
  return bytes.toString() + ' B';
}

String _friendly(Object error) {
  if (error is TimeoutException) return 'انتهت مهلة الاتصال بالراوتر.';
  if (error is RouterOsException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
