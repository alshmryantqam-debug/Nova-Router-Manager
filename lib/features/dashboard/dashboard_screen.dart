import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _bg = Color(0xFF080B12);
const Color _panel = Color(0xFF111722);
const Color _muted = Color(0xFF8D9AB0);
const Color _accent = Color(0xFF8B7CFF);
const Color _rxColor = Color(0xFF43D9A3);
const Color _txColor = Color(0xFF67B7FF);
const Color _danger = Color(0xFFFF657A);

enum _DashboardSection { home, hotspot, pppoe, queues, firewall }

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  late final RouterOsClient? _client;
  late final Stream<DashboardSnapshot> _snapshotStream;
  _DashboardSection _section = _DashboardSection.home;
  List<RouterInterface> _interfaces = <RouterInterface>[];
  String? _selectedInterface;
  String? _interfaceError;
  bool _loadingInterfaces = true;
  StreamSubscription<Map<String, String>>? _trafficSubscription;
  Timer? _trafficRetryTimer;
  int _trafficGeneration = 0;
  int _sampleIndex = 0;
  double _currentRxMbps = 0;
  double _currentTxMbps = 0;
  String? _trafficError;
  final List<FlSpot> _rxSpots = <FlSpot>[];
  final List<FlSpot> _txSpots = <FlSpot>[];

  @override
  void initState() {
    super.initState();
    _client = ref.read(activeRouterClientProvider);
    final client = _client;
    _snapshotStream = client == null ? const Stream<DashboardSnapshot>.empty() : _watchDashboard(client);
    if (client != null) {
      unawaited(_loadInterfaces(client));
    } else {
      _loadingInterfaces = false;
    }
  }

  @override
  void dispose() {
    _trafficGeneration++;
    _trafficRetryTimer?.cancel();
    final subscription = _trafficSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  static Future<List<Map<String, String>>> _safeCommand(RouterOsClient client, String path) async {
    try {
      return await client.command(path);
    } catch (_) {
      return <Map<String, String>>[];
    }
  }

  Stream<DashboardSnapshot> _watchDashboard(RouterOsClient client) async* {
    final identityRows = await _safeCommand(client, '/system/identity/print');
    final boardRows = await _safeCommand(client, '/system/routerboard/print');
    final identity = identityRows.isEmpty ? '' : (identityRows.first['name'] ?? '');
    final board = boardRows.isEmpty ? <String, String>{} : Map<String, String>.from(boardRows.first);

    while (true) {
      try {
        final results = await Future.wait<List<Map<String, String>>>([
          client.command('/system/resource/print'),
          _safeCommand(client, '/system/health/print'),
        ]);
        final resource = results[0].isEmpty ? <String, String>{} : Map<String, String>.from(results[0].first);
        final health = _flattenHealth(results[1]);
        final boardName = (resource['board-name'] ?? '').trim();
        final boardModel = (board['model'] ?? board['board-name'] ?? '').trim();
        yield DashboardSnapshot(
          identity: identity.isEmpty ? 'غير معروف' : identity,
          boardName: boardName.isNotEmpty ? boardName : (boardModel.isNotEmpty ? boardModel : 'غير متاح'),
          version: resource['version'] ?? 'غير متاح',
          resource: resource,
          health: health,
          routerboard: board,
        );
      } catch (error) {
        yield DashboardSnapshot(
          identity: identity.isEmpty ? 'غير معروف' : identity,
          boardName: board['model'] ?? board['board-name'] ?? 'غير متاح',
          version: '—',
          resource: const <String, String>{},
          health: const <String, String>{},
          routerboard: board,
          error: _friendlyError(error),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }

  static Map<String, String> _flattenHealth(List<Map<String, String>> rows) {
    final result = <String, String>{};
    for (final row in rows) {
      result.addAll(row);
      final name = row['name'];
      final value = row['value'];
      if (name != null && value != null) result[name] = value;
    }
    return result;
  }

  Future<void> _loadInterfaces(RouterOsClient client) async {
    if (mounted) setState(() { _loadingInterfaces = true; _interfaceError = null; });
    try {
      final rows = await client.command(
        '/interface/print',
        args: const <String, String>{'.proplist': 'name,type,disabled,running'},
      );
      final interfaces = rows
          .where((row) => (row['name'] ?? '').trim().isNotEmpty)
          .map(RouterInterface.fromMap)
          .toList(growable: false)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      final old = _selectedInterface;
      final selected = interfaces.any((item) => item.name == old) ? old : (interfaces.isEmpty ? null : interfaces.first.name);
      setState(() {
        _interfaces = interfaces;
        _selectedInterface = selected;
        _loadingInterfaces = false;
        _interfaceError = interfaces.isEmpty ? 'لم يُرجع الراوتر أي واجهات.' : null;
      });
      if (selected != null) _subscribeTraffic(selected);
    } catch (error) {
      if (!mounted) return;
      setState(() { _loadingInterfaces = false; _interfaceError = _friendlyError(error); });
    }
  }

  void _subscribeTraffic(String interfaceName) {
    final client = _client;
    if (client == null || !mounted) return;
    final generation = ++_trafficGeneration;
    _trafficRetryTimer?.cancel();
    _trafficRetryTimer = null;
    final previous = _trafficSubscription;
    _trafficSubscription = null;
    if (previous != null) unawaited(previous.cancel());

    setState(() {
      _sampleIndex = 0;
      _currentRxMbps = 0;
      _currentTxMbps = 0;
      _trafficError = null;
      _rxSpots.clear();
      _txSpots.clear();
    });

    try {
      _trafficSubscription = client.monitorStream(
        '/interface/monitor-traffic',
        args: <String, String>{'interface': interfaceName},
      ).listen(
        (row) {
          if (!mounted || generation != _trafficGeneration) return;
          final rx = _toMbps(row['rx-bits-per-second']);
          final tx = _toMbps(row['tx-bits-per-second']);
          setState(() {
            _currentRxMbps = rx;
            _currentTxMbps = tx;
            _trafficError = null;
            _rxSpots.add(FlSpot(_sampleIndex.toDouble(), rx));
            _txSpots.add(FlSpot(_sampleIndex.toDouble(), tx));
            _sampleIndex++;
            while (_rxSpots.length > 60) {
              _rxSpots.removeAt(0);
              _txSpots.removeAt(0);
            }
          });
        },
        onError: (Object error, StackTrace stack) => _scheduleTrafficRetry(interfaceName, generation, error),
        onDone: () => _scheduleTrafficRetry(interfaceName, generation, const RouterOsException('انتهى بث الترافيك')),
        cancelOnError: true,
      );
    } catch (error) {
      _scheduleTrafficRetry(interfaceName, generation, error);
    }
  }

  void _scheduleTrafficRetry(String interfaceName, int generation, Object error) {
    if (!mounted || generation != _trafficGeneration) return;
    setState(() => _trafficError = _friendlyError(error));
    if (_trafficRetryTimer?.isActive ?? false) return;
    _trafficRetryTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && generation == _trafficGeneration && _selectedInterface == interfaceName) {
        _subscribeTraffic(interfaceName);
      }
    });
  }

  void _selectInterface(String? name) {
    if (name == null || name == _selectedInterface) return;
    setState(() => _selectedInterface = name);
    _subscribeTraffic(name);
  }

  void _selectSection(_DashboardSection section) {
    Navigator.of(context).pop();
    if (section != _section) setState(() => _section = section);
  }

  Future<void> _disconnect() async {
    Navigator.of(context).pop();
    await ref.read(activeRouterClientProvider.notifier).disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final activeRouter = ref.watch(activeRouterDetailsProvider);
    final client = ref.watch(activeRouterClientProvider);
    if (client == null || !identical(client, _client)) {
      return const Scaffold(backgroundColor: _bg, body: Center(child: CircularProgressIndicator(color: _accent)));
    }

    return Scaffold(
      backgroundColor: _bg,
      drawer: _buildDrawer(activeRouter),
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 12,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_sectionTitle(_section), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text(activeRouter == null ? 'جلسة RouterOS' : activeRouter.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 10)),
        ]),
        actions: [
          if (_section == _DashboardSection.home)
            IconButton(
              tooltip: 'تحديث الواجهات',
              onPressed: _loadingInterfaces ? null : () => unawaited(_loadInterfaces(client)),
              icon: const Icon(Icons.refresh_rounded, color: _accent),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _section == _DashboardSection.home
          ? _buildHome()
          : _RouterRecordsPanel(key: ValueKey<_DashboardSection>(_section), client: client, section: _section),
    );
  }

  Widget _buildDrawer(SavedRouter? activeRouter) => Drawer(
        backgroundColor: _panel,
        child: SafeArea(
          child: Column(children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [Color(0xFF292647), Color(0xFF111722)]),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: 54, height: 54, decoration: BoxDecoration(color: _accent.withOpacity(0.18), borderRadius: BorderRadius.circular(17)), child: const Icon(Icons.hub_rounded, size: 31, color: _accent)),
                const SizedBox(height: 14),
                const Text('NOVA ROUTER', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
                const SizedBox(height: 5),
                Text(activeRouter?.name ?? 'جلسة إدارة الشبكة', style: const TextStyle(color: _muted, fontSize: 12)),
                if (activeRouter != null) ...[
                  const SizedBox(height: 4),
                  Text(activeRouter.host + ':' + activeRouter.port.toString(), textDirection: TextDirection.ltr, style: const TextStyle(color: _muted, fontSize: 11)),
                ],
              ]),
            ),
            const SizedBox(height: 10),
            _drawerItem(_DashboardSection.home, Icons.dashboard_rounded, 'الرئيسية'),
            _drawerItem(_DashboardSection.hotspot, Icons.wifi_tethering_rounded, 'الهوتسبوت'),
            _drawerItem(_DashboardSection.pppoe, Icons.settings_ethernet_rounded, 'مشتركو PPPoE'),
            _drawerItem(_DashboardSection.queues, Icons.speed_rounded, 'الطوابير والسرعات'),
            _drawerItem(_DashboardSection.firewall, Icons.security_rounded, 'الشبكة والفايروول'),
            const Spacer(),
            const Divider(color: Color(0xFF283142), height: 1),
            ListTile(
              leading: const Icon(Icons.router_outlined, color: _muted),
              title: const Text('اختيار راوتر آخر', style: TextStyle(color: Colors.white, fontSize: 13)),
              onTap: _disconnect,
            ),
            const SizedBox(height: 10),
          ]),
        ),
      );

  Widget _drawerItem(_DashboardSection section, IconData icon, String label) {
    final selected = _section == section;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
        selected: selected,
        selectedTileColor: _accent.withOpacity(0.14),
        leading: Icon(icon, color: selected ? _accent : _muted, size: 21),
        title: Text(label, style: TextStyle(color: selected ? Colors.white : const Color(0xFFCAD2E0), fontWeight: selected ? FontWeight.w800 : FontWeight.w500, fontSize: 13)),
        trailing: selected ? const Icon(Icons.chevron_left_rounded, color: _accent) : null,
        onTap: () => _selectSection(section),
      ),
    );
  }

  String _sectionTitle(_DashboardSection section) {
    switch (section) {
      case _DashboardSection.home: return 'مركز المراقبة';
      case _DashboardSection.hotspot: return 'الهوتسبوت';
      case _DashboardSection.pppoe: return 'مشتركو PPPoE';
      case _DashboardSection.queues: return 'الطوابير والسرعات';
      case _DashboardSection.firewall: return 'الشبكة والفايروول';
    }
  }

  Widget _buildHome() => StreamBuilder<DashboardSnapshot>(
        stream: _snapshotStream,
        builder: (context, snapshot) {
          if (!snapshot.hasData && !snapshot.hasError) {
            return const Center(child: CircularProgressIndicator(color: _accent));
          }
          if (snapshot.hasError) {
            return _CenteredMessage(icon: Icons.cloud_off_rounded, title: 'تعذّر قراءة موارد الراوتر', message: _friendlyError(snapshot.error!));
          }

          final data = snapshot.data!;
          final resource = data.resource;
          final health = data.health;
          final cpu = _number(resource['cpu-load']);
          final cores = int.tryParse(resource['cpu-count'] ?? '');
          final totalMemory = _number(resource['total-memory']) ?? 0;
          final freeMemory = _number(resource['free-memory']) ?? 0;
          final usedMemory = math.max(0.0, totalMemory - freeMemory).toDouble();
          final ramPercent = totalMemory > 0 ? (usedMemory / totalMemory) * 100 : null;
          final uptime = resource['uptime'] ?? '—';
          final temperature = _firstNonEmpty([
            health['cpu-temperature'], health['temperature'], health['board-temperature1'],
            health['board-temperature'], resource['cpu-temperature'], resource['temperature'],
          ]);
          final voltage = _firstNonEmpty([health['voltage'], resource['voltage']]);

          return RefreshIndicator(
            color: _accent,
            backgroundColor: _panel,
            onRefresh: () async => _loadInterfaces(_client!),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              children: [
                _SystemHeader(
                  identity: data.identity,
                  boardName: data.boardName,
                  version: data.version,
                  host: ref.read(activeRouterDetailsProvider)?.host ?? '',
                ),
                if (data.error != null) ...[
                  const SizedBox(height: 12),
                  _NoticeBanner(color: _danger, icon: Icons.warning_amber_rounded, text: 'تعذر تحديث بعض القراءات: ' + data.error!),
                ],
                const SizedBox(height: 14),
                const _SectionHeading(title: 'الموارد الحية', subtitle: 'تحديث تلقائي كل ثانية'),
                const SizedBox(height: 10),
                GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.12,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _GaugeCard(
                      title: 'المعالج CPU',
                      value: cpu == null ? '—' : cpu.toStringAsFixed(0) + '%',
                      subtitle: cpu == null ? 'لا توجد قراءة' : 'استهلاك المعالج',
                      icon: Icons.memory_rounded,
                      color: const Color(0xFFFFB45E),
                      progress: cpu == null ? null : (cpu / 100).clamp(0.0, 1.0).toDouble(),
                    ),
                    _GaugeCard(
                      title: 'أنوية المعالج',
                      value: cores?.toString() ?? '—',
                      subtitle: resource['cpu'] ?? resource['cpu-frequency'] ?? 'CPU cores',
                      icon: Icons.developer_board_rounded,
                      color: _accent,
                      progress: null,
                    ),
                    _GaugeCard(
                      title: 'ذاكرة RAM',
                      value: totalMemory <= 0 ? '—' : (usedMemory / (1024 * 1024)).toStringAsFixed(0) + ' MB',
                      subtitle: ramPercent == null ? 'لا توجد قراءة' : ramPercent.clamp(0.0, 100.0).toStringAsFixed(1) + '% مستخدمة',
                      icon: Icons.storage_rounded,
                      color: _txColor,
                      progress: ramPercent == null ? null : (ramPercent / 100).clamp(0.0, 1.0).toDouble(),
                    ),
                    _GaugeCard(
                      title: 'وقت التشغيل',
                      value: uptime,
                      subtitle: 'Uptime',
                      icon: Icons.timelapse_rounded,
                      color: _rxColor,
                      progress: null,
                      compactValue: true,
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                const _SectionHeading(title: 'المراقبة الحرارية والكهربائية', subtitle: 'القيم المتاحة من /system/health'),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: _SmallMetricCard(title: 'الحرارة', value: _formatSensor(temperature, '°C'), icon: Icons.thermostat_rounded, color: const Color(0xFFFF8A65))),
                  const SizedBox(width: 10),
                  Expanded(child: _SmallMetricCard(title: 'الفولتية', value: _formatSensor(voltage, 'V'), icon: Icons.bolt_rounded, color: const Color(0xFFFFD166))),
                ]),
                const SizedBox(height: 22),
                _buildTrafficPanel(),
              ],
            ),
          );
        },
      );

  Widget _buildTrafficPanel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(22), border: Border.all(color: Colors.white.withOpacity(0.065))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Row(children: [
          Icon(Icons.multiline_chart_rounded, color: _accent, size: 21),
          SizedBox(width: 8),
          Expanded(child: Text('Live Traffic Graph', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800))),
          Icon(Icons.wifi_tethering_rounded, color: _rxColor, size: 17),
        ]),
        const SizedBox(height: 5),
        const Text('سرعة السحب والرفع لحظيًا بوحدة Mbps', style: TextStyle(color: _muted, fontSize: 11)),
        const SizedBox(height: 16),
        if (_loadingInterfaces)
          const LinearProgressIndicator(color: _accent, backgroundColor: Color(0xFF263042))
        else if (_interfaceError != null && _interfaces.isEmpty)
          _NoticeBanner(color: _danger, icon: Icons.error_outline_rounded, text: _interfaceError!)
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(13), border: Border.all(color: Colors.white.withOpacity(0.07))),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _interfaces.any((item) => item.name == _selectedInterface) ? _selectedInterface : null,
                isExpanded: true,
                dropdownColor: const Color(0xFF171F2C),
                icon: const Icon(Icons.expand_more_rounded, color: _accent),
                hint: const Text('اختر كرت الشبكة أو بريدج المشتركين', style: TextStyle(color: _muted, fontSize: 12)),
                items: _interfaces.map((item) {
                  final status = item.running ? 'UP' : item.disabled ? 'DISABLED' : 'DOWN';
                  return DropdownMenuItem<String>(
                    value: item.name,
                    child: Row(children: [
                      Icon(Icons.lan_rounded, size: 16, color: item.running ? _rxColor : _muted),
                      const SizedBox(width: 9),
                      Expanded(child: Text(item.name, textDirection: TextDirection.ltr, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12))),
                      Text(status, style: TextStyle(color: item.running ? _rxColor : _muted, fontSize: 9, fontWeight: FontWeight.w800)),
                    ]),
                  );
                }).toList(growable: false),
                onChanged: _selectInterface,
              ),
            ),
          ),
        if (_interfaceError != null && _interfaces.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_interfaceError!, style: const TextStyle(color: _danger, fontSize: 10)),
        ],
        const SizedBox(height: 17),
        Row(children: [
          Expanded(child: _TrafficValue(label: 'RX · سحب', value: _currentRxMbps, color: _rxColor)),
          const SizedBox(width: 10),
          Expanded(child: _TrafficValue(label: 'TX · رفع', value: _currentTxMbps, color: _txColor)),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 210,
          child: _rxSpots.isEmpty
              ? Center(
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(_trafficError == null ? Icons.multiline_chart_rounded : Icons.sync_problem_rounded, size: 31, color: _muted),
                    const SizedBox(height: 8),
                    Text(_trafficError ?? (_selectedInterface == null ? 'حدد واجهة لبدء القياس' : 'في انتظار عينات الترافيك...'), textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 11)),
                    if (_trafficError != null) ...[
                      const SizedBox(height: 10),
                      TextButton.icon(onPressed: _selectedInterface == null ? null : () => _subscribeTraffic(_selectedInterface!), icon: const Icon(Icons.refresh_rounded, size: 16), label: const Text('إعادة المحاولة')),
                    ],
                  ]),
                )
              : _buildLineChart(),
        ),
        const SizedBox(height: 8),
        const Row(children: [
          _LegendDot(color: _rxColor, label: 'RX'),
          SizedBox(width: 18),
          _LegendDot(color: _txColor, label: 'TX'),
          Spacer(),
          Text('آخر 60 عينة', style: TextStyle(color: _muted, fontSize: 10)),
        ]),
      ]),
    );
  }

  Widget _buildLineChart() {
    final values = <double>[..._rxSpots.map((spot) => spot.y), ..._txSpots.map((spot) => spot.y)];
    final highest = values.fold<double>(0, (current, value) => math.max(current, value).toDouble());
    final maxY = math.max(5.0, (highest / 5).ceilToDouble() * 5).toDouble();
    final lastX = _rxSpots.isEmpty ? 10.0 : _rxSpots.last.x;
    final minX = math.max(0.0, lastX - 29.0).toDouble();
    final maxX = math.max(10.0, lastX).toDouble();

    return LineChart(
      LineChartData(
        minX: minX,
        maxX: maxX,
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: true,
          horizontalInterval: maxY / 4,
          getDrawingHorizontalLine: (value) => FlLine(color: Colors.white.withOpacity(0.065), strokeWidth: 1),
          getDrawingVerticalLine: (value) => FlLine(color: Colors.white.withOpacity(0.035), strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 38,
              interval: maxY / 4,
              getTitlesWidget: (value, meta) => Text(value.toStringAsFixed(0), style: const TextStyle(color: _muted, fontSize: 9)),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 23,
              interval: math.max(1.0, (maxX - minX) / 4).toDouble(), 
              getTitlesWidget: (value, meta) => Text(value.toStringAsFixed(0), style: const TextStyle(color: _muted, fontSize: 9)),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((spot) {
              final label = spot.barIndex == 0 ? 'RX' : 'TX';
              return LineTooltipItem(
                label + '  ' + spot.y.toStringAsFixed(2) + ' Mbps',
                TextStyle(color: spot.bar.color ?? Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
              );
            }).toList(growable: false),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: _rxSpots,
            isCurved: true,
            curveSmoothness: 0.18,
            color: _rxColor,
            barWidth: 2.3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: true, color: _rxColor.withOpacity(0.09)),
          ),
          LineChartBarData(
            spots: _txSpots,
            isCurved: true,
            curveSmoothness: 0.18,
            color: _txColor,
            barWidth: 2.3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(show: true, color: _txColor.withOpacity(0.07)),
          ),
        ],
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }
}

class DashboardSnapshot {
  const DashboardSnapshot({
    required this.identity,
    required this.boardName,
    required this.version,
    required this.resource,
    required this.health,
    required this.routerboard,
    this.error,
  });

  final String identity;
  final String boardName;
  final String version;
  final Map<String, String> resource;
  final Map<String, String> health;
  final Map<String, String> routerboard;
  final String? error;
}

class RouterInterface {
  const RouterInterface({required this.name, required this.type, required this.disabled, required this.running});

  final String name;
  final String type;
  final bool disabled;
  final bool running;

  factory RouterInterface.fromMap(Map<String, String> row) => RouterInterface(
        name: row['name'] ?? '',
        type: row['type'] ?? 'unknown',
        disabled: row['disabled'] == 'true',
        running: row['running'] == 'true',
      );
}

class _SystemHeader extends StatelessWidget {
  const _SystemHeader({required this.identity, required this.boardName, required this.version, required this.host});
  final String identity;
  final String boardName;
  final String version;
  final String host;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [Color(0xFF292647), Color(0xFF172131), Color(0xFF111722)]),
          border: Border.all(color: _accent.withOpacity(0.27)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(width: 45, height: 45, decoration: BoxDecoration(color: _accent.withOpacity(0.18), borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.router_rounded, color: _accent, size: 26)),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('ROUTER IDENTITY', style: TextStyle(color: _muted, fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
              const SizedBox(height: 4),
              Text(identity, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w900)),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(color: _rxColor.withOpacity(0.12), borderRadius: BorderRadius.circular(9)),
              child: const Row(children: [Icon(Icons.circle, size: 6, color: _rxColor), SizedBox(width: 5), Text('LIVE', style: TextStyle(color: _rxColor, fontSize: 9, fontWeight: FontWeight.w900))]),
            ),
          ]),
          const SizedBox(height: 17),
          const Divider(color: Color(0x332D3B50), height: 1),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _IdentityValue(label: 'BOARD NAME', value: boardName, icon: Icons.developer_board_outlined)),
            const SizedBox(width: 12),
            Expanded(child: _IdentityValue(label: 'ROUTEROS VERSION', value: version, icon: Icons.terminal_rounded)),
          ]),
          if (host.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(children: [
              const Icon(Icons.link_rounded, color: _muted, size: 14),
              const SizedBox(width: 6),
              Expanded(child: Text(host, textDirection: TextDirection.ltr, style: const TextStyle(color: _muted, fontSize: 11))),
            ]),
          ],
        ]),
      );
}

class _IdentityValue extends StatelessWidget {
  const _IdentityValue({required this.label, required this.value, required this.icon});
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: _accent, size: 13),
          const SizedBox(width: 5),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 8, fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 6),
        Text(value, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
      ]);
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: _muted, fontSize: 10)),
      ]);
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({required this.title, required this.value, required this.subtitle, required this.icon, required this.color, required this.progress, this.compactValue = false});
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;
  final double? progress;
  final bool compactValue;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(19), border: Border.all(color: Colors.white.withOpacity(0.06))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 30, height: 30, decoration: BoxDecoration(color: color.withOpacity(0.13), borderRadius: BorderRadius.circular(10)), child: Icon(icon, color: color, size: 17)),
            const SizedBox(width: 7),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 10, fontWeight: FontWeight.w700))),
          ]),
          const Spacer(),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white, fontSize: compactValue ? 18 : 25, fontWeight: FontWeight.w900, letterSpacing: -0.4)),
          const SizedBox(height: 6),
          Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 9)),
          if (progress != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(value: progress!.clamp(0.0, 1.0).toDouble(), minHeight: 4, backgroundColor: Colors.white.withOpacity(0.07), valueColor: AlwaysStoppedAnimation<Color>(color)),
            ),
          ],
        ]),
      );
}

class _SmallMetricCard extends StatelessWidget {
  const _SmallMetricCard({required this.title, required this.value, required this.icon, required this.color});
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withOpacity(0.06))),
        child: Row(children: [
          Container(width: 37, height: 37, decoration: BoxDecoration(color: color.withOpacity(0.13), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color, size: 21)),
          const SizedBox(width: 11),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: _muted, fontSize: 11)),
            const SizedBox(height: 5),
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
          ])),
        ]),
      );
}

class _TrafficValue extends StatelessWidget {
  const _TrafficValue({required this.label, required this.value, required this.color});
  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
        decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(13)),
        child: Row(children: [
          Container(width: 3, height: 27, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4))),
          const SizedBox(width: 9),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(color: _muted, fontSize: 10)),
            const SizedBox(height: 3),
            Text(value.toStringAsFixed(2) + ' Mbps', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w900)),
          ])),
        ]),
      );
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w800)),
      ]);
}

class _RouterRecordsPanel extends StatefulWidget {
  const _RouterRecordsPanel({super.key, required this.client, required this.section});
  final RouterOsClient client;
  final _DashboardSection section;

  @override
  State<_RouterRecordsPanel> createState() => _RouterRecordsPanelState();
}

class _RouterRecordsPanelState extends State<_RouterRecordsPanel> {
  String _firewallPath = '/ip/firewall/filter/print';
  late Future<List<Map<String, String>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadRecords();
  }

  String get _commandPath {
    switch (widget.section) {
      case _DashboardSection.hotspot: return '/ip/hotspot/user/print';
      case _DashboardSection.pppoe: return '/ppp/secret/print';
      case _DashboardSection.queues: return '/queue/simple/print';
      case _DashboardSection.firewall: return _firewallPath;
      case _DashboardSection.home: return '/system/resource/print';
    }
  }

  String get _title {
    switch (widget.section) {
      case _DashboardSection.hotspot: return 'مستخدمو الهوتسبوت';
      case _DashboardSection.pppoe: return 'حسابات PPPoE';
      case _DashboardSection.queues: return 'Simple Queues';
      case _DashboardSection.firewall: return 'قواعد الفايروول';
      case _DashboardSection.home: return 'موارد الراوتر';
    }
  }

  String get _subtitle {
    switch (widget.section) {
      case _DashboardSection.hotspot: return '/ip/hotspot/user/print';
      case _DashboardSection.pppoe: return '/ppp/secret/print';
      case _DashboardSection.queues: return '/queue/simple/print';
      case _DashboardSection.firewall: return _firewallPath;
      case _DashboardSection.home: return _commandPath;
    }
  }

  Future<List<Map<String, String>>> _loadRecords() => widget.client.command(_commandPath);

  void _reload() => setState(() {
        _future = _loadRecords();
      });

  void _changeFirewallPath(String? path) {
    if (path == null || path == _firewallPath) return;
    setState(() {
      _firewallPath = path;
      _future = _loadRecords();
    });
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        if (widget.section == _DashboardSection.firewall)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(13), border: Border.all(color: Colors.white.withOpacity(0.06))),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _firewallPath,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF171F2C),
                  items: const [
                    DropdownMenuItem(value: '/ip/firewall/filter/print', child: Text('Filter Rules')),
                    DropdownMenuItem(value: '/ip/firewall/mangle/print', child: Text('Mangle Rules')),
                    DropdownMenuItem(value: '/ip/firewall/raw/print', child: Text('RAW Rules')),
                  ],
                  onChanged: _changeFirewallPath,
                ),
              ),
            ),
          ),
        Expanded(
          child: FutureBuilder<List<Map<String, String>>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: _accent));
              if (snapshot.hasError) return _CenteredMessage(icon: Icons.cloud_off_rounded, title: 'تعذر تحميل البيانات', message: _friendlyError(snapshot.error!));
              final records = snapshot.data ?? <Map<String, String>>[];
              return RefreshIndicator(
                color: _accent,
                backgroundColor: _panel,
                onRefresh: () async {
                  final future = _loadRecords();
                  setState(() => _future = future);
                  await future;
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF242242), Color(0xFF111722)]), borderRadius: BorderRadius.circular(19), border: Border.all(color: _accent.withOpacity(0.2))),
                      child: Row(children: [
                        const Icon(Icons.storage_rounded, color: _accent, size: 24),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(_title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(_subtitle, textDirection: TextDirection.ltr, style: const TextStyle(color: _muted, fontSize: 9)),
                        ])),
                        Text(records.length.toString(), style: const TextStyle(color: _rxColor, fontSize: 23, fontWeight: FontWeight.w900)),
                        IconButton(tooltip: 'تحديث', onPressed: _reload, icon: const Icon(Icons.refresh_rounded, color: _accent)),
                      ]),
                    ),
                    if (records.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 42),
                        child: _CenteredMessage(icon: Icons.inbox_outlined, title: 'لا توجد سجلات للعرض', message: 'لا توجد عناصر مطابقة أو أن حساب RouterOS لا يملك صلاحية قراءتها.'),
                      )
                    else
                      ...records.map((record) => _RecordCard(record: record)),
                  ],
                ),
              );
            },
          ),
        ),
      ]);
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.record});
  final Map<String, String> record;

  @override
  Widget build(BuildContext context) {
    final id = _firstNonEmpty([
      record['name'], record['user'], record['username'], record['interface'],
      record['target'], record['address'], record['.id'], record['chain'],
    ]) ?? 'RouterOS entry';
    final details = record.entries
        .where((entry) => !['name', 'user', 'username', 'interface', 'target', 'address', '.id'].contains(entry.key))
        .where((entry) => entry.value.isNotEmpty)
        .take(3)
        .map((entry) => entry.key + ': ' + entry.value)
        .join('  ·  ');

    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(0.055))),
      child: ListTile(
        leading: Container(width: 38, height: 38, decoration: BoxDecoration(color: _accent.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.article_outlined, color: _accent, size: 20)),
        title: Text(id, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
        subtitle: details.isEmpty ? null : Padding(padding: const EdgeInsets.only(top: 5), child: Text(details, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 10, height: 1.4))),
        trailing: const Icon(Icons.chevron_left_rounded, color: _muted, size: 20),
      ),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.color, required this.icon, required this.text});
  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(13), border: Border.all(color: color.withOpacity(0.28))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: TextStyle(color: color, fontSize: 11, height: 1.4))),
        ]),
      );
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: _accent, size: 42),
            const SizedBox(height: 15),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 12, height: 1.5)),
          ]),
        ),
      );
}

double? _number(String? source) {
  if (source == null) return null;
  final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(source);
  return match == null ? null : double.tryParse(match.group(0)!);
}

double _toMbps(String? bitsPerSecond) => (_number(bitsPerSecond) ?? 0) / 1000000;

String? _firstNonEmpty(Iterable<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

String _formatSensor(String? value, String unit) {
  if (value == null || value.trim().isEmpty || value == '—') return 'غير متاح';
  final trimmed = value.trim();
  return RegExp(r'[a-zA-Z°]').hasMatch(trimmed) ? trimmed : trimmed + ' ' + unit;
}

String _friendlyError(Object error) {
  if (error is TimeoutException) return 'انتهت مهلة الاتصال. تحقق من العنوان والمنفذ.';
  if (error is RouterOsException) return error.message;
  if (error is SocketException) return 'تعذر الوصول إلى الراوتر أو أن منفذ API مغلق.';
  final message = error.toString();
  return message.startsWith('Exception: ') ? message.substring(11) : message;
}
