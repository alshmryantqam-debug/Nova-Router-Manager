import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';
import '../../core/storage/router_storage_service.dart';
import '../hotspot/hotspot_screen.dart';
import '../quick_actions/global_search_screen.dart';
import '../users_monitor/unified_active_users_screen.dart';
import '../hotspot/hotspot_template_installer_screen.dart';
import '../dhcp_binding/dhcp_binding_screen.dart';
import '../system/system_manager_screen.dart';
import '../network/network_tools_screen.dart';
import '../pppoe/pppoe_screen.dart';
import '../queues/queues_screen.dart';
import '../neighbors/neighbors_connections_screen.dart';
import '../interfaces/interfaces_screen.dart';
import '../diagnostics/live_torch_screen.dart';
import '../diagnostics/api_terminal_screen.dart';
import '../network/netwatch_wan_screen.dart';
import '../hotspot/hotspot_sales_report_screen.dart';
import '../ip_management/ip_arp_dns_screen.dart';
import '../diagnostics/bandwidth_test_screen.dart';
import '../settings/app_settings_screen.dart';
import '../settings/app_security_service.dart';
import '../remote_access/wireguard_tunnel_screen.dart';
import '../remote_access/cgnat_bypass_screen.dart';
import '../remote_access/external_security_portfwd_screen.dart';
import '../wireless_towers/wireless_towers_screen.dart';
import '../automation/raw_qos_wizard_screen.dart';
import '../automation/telegram_alerts_screen.dart';
import '../firewall_advanced/nat_address_list_screen.dart';
import '../firewall_advanced/pcc_wizard_screen.dart';

const Color _bg = Color(0xFF080B12);
const Color _panel = Color(0xFF111722);
const Color _muted = Color(0xFF8D9AB0);
const Color _accent = Color(0xFF35D7F2);
const Color _rxColor = Color(0xFF43D9A3);
const Color _txColor = Color(0xFF67B7FF);
const Color _danger = Color(0xFFFF657A);

enum _DashboardSection { home, networkMap, tools, monitoring, appSettings, hotspot, pppoe, queues, firewall, neighbors, dhcpBinding, system, interfaces, liveTorch, apiTerminal, netwatch, hotspotSales, ipArpDns, natAddressLists, pccWizard, bandwidthTest, appSettings, remoteAccess, cgnatBypass, externalSecurity, wirelessTowers, rawQosWizard, telegramAlerts, hotspotTemplateInstaller }

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
  int _monitorTab = 0;
  double _currentRxMbps = 0;
  double _currentTxMbps = 0;
  bool _hasTrafficSample = false;
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
      final refreshInterval = await AppSecurityService.getRefreshInterval().catchError((Object _) => 1);
      await Future<void>.delayed(Duration(seconds: refreshInterval));
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
      _hasTrafficSample = false;
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
            _hasTrafficSample = true;
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
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    if (section != _section) setState(() => _section = section);
  }

  Future<void> _disconnect() async {
    Scaffold.maybeOf(context)?.closeDrawer();
    await ref.read(activeRouterClientProvider.notifier).disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final activeRouter = ref.watch(activeRouterDetailsProvider);
    final client = ref.watch(activeRouterClientProvider);
    if (client == null || !identical(client, _client)) {
      return const Scaffold(backgroundColor: _bg, body: Center(child: CircularProgressIndicator(color: _accent)));
    }

    return PopScope<Object?>(
      canPop: _section == _DashboardSection.home,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _section != _DashboardSection.home && mounted) {
          setState(() => _section = _DashboardSection.home);
        }
      },
      child: Scaffold(
      backgroundColor: _bg,
      drawer: _buildDrawer(activeRouter),
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleSpacing: 0,
        title: _section == _DashboardSection.home
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                ShaderMask(shaderCallback: (bounds) => const LinearGradient(colors: [Color(0xFF7DF9FF), Color(0xFF00D2FF), Color(0xFF0077FF)]).createShader(bounds), child: const Text('NOVA', style: TextStyle(color: Colors.white, fontSize: 27, height: 1, fontWeight: FontWeight.w900, letterSpacing: 2.5))),
                const Text('Router Manager', style: TextStyle(color: Color(0xFFD8E8FF), fontSize: 10, height: 1.25, fontWeight: FontWeight.w600, letterSpacing: .4)),
              ])
            : Text(_sectionTitle(_section), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
        leading: Builder(builder: (menuContext) => IconButton(tooltip: 'القائمة', onPressed: () => Scaffold.of(menuContext).openDrawer(), icon: const Icon(Icons.menu_rounded, color: _accent, size: 26))),
        actions: [
          IconButton(
            tooltip: 'البحث الشامل عن مشترك أو كرت أو IP أو MAC',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const GlobalSearchScreen()),
            ),
            icon: const Icon(Icons.search_rounded, color: _accent),
          ),
          IconButton(tooltip: 'المراقبة والتنبيهات', onPressed: () => _selectSection(_DashboardSection.monitoring), icon: const Icon(Icons.notifications_none_rounded, color: _accent)),
          if (_section == _DashboardSection.home)
            IconButton(tooltip: 'تحديث الواجهات', onPressed: _loadingInterfaces ? null : () => unawaited(_loadInterfaces(client)), icon: const Icon(Icons.refresh_rounded, color: _accent)),
          const SizedBox(width: 8),
        ],
      ),
      body: _section == _DashboardSection.home
          ? _buildHome()
          : _section == _DashboardSection.networkMap
              ? _buildNetworkMap()
              : _section == _DashboardSection.tools
                  ? _buildTools()
                  : _section == _DashboardSection.monitoring
                      ? _buildMonitoring()
                      : _section == _DashboardSection.hotspot
              ? const HotspotScreen()
              : _section == _DashboardSection.pppoe
                  ? const PppoeScreen()
                  : _section == _DashboardSection.queues
                      ? const QueuesScreen()
                      : _section == _DashboardSection.neighbors
                          ? const NeighborsConnectionsScreen()
                          : _section == _DashboardSection.dhcpBinding
                              ? const DhcpBindingScreen()
                              : _section == _DashboardSection.system
                                  ? const SystemManagerScreen()
                                  : _section == _DashboardSection.interfaces
                                      ? const InterfacesScreen()
                                      : _section == _DashboardSection.liveTorch
                                          ? const LiveTorchScreen()
                                          : _section == _DashboardSection.apiTerminal
                                              ? const ApiTerminalScreen()
                                              : _section == _DashboardSection.netwatch
                                                  ? const NetwatchWanScreen()
                                                  : _section == _DashboardSection.hotspotSales
                                                      ? const HotspotSalesReportScreen()
                                                      : _section == _DashboardSection.ipArpDns
                                                          ? const IpArpDnsScreen()
                                                          : _section == _DashboardSection.natAddressLists
                                                              ? const NatAddressListScreen()
                                                              : _section == _DashboardSection.pccWizard
                                                                  ? const PccWizardScreen()
                                                                  : _section == _DashboardSection.bandwidthTest
                                                                      ? const BandwidthTestScreen()
                                                                      : _section == _DashboardSection.appSettings
                                                                          ? _buildReferenceSettings()
                                                                          : _section == _DashboardSection.remoteAccess
                                                                              ? const WireguardTunnelScreen()
                                                                              : _section == _DashboardSection.cgnatBypass
                                                                                  ? const CgnatBypassScreen()
                                                                                  : _section == _DashboardSection.externalSecurity
                                                                                      ? const ExternalSecurityPortfwdScreen()
                                                                                      : _section == _DashboardSection.wirelessTowers
                                                                                          ? const WirelessTowersScreen()
                                                                                          : _section == _DashboardSection.rawQosWizard
                                                                                              ? const RawQosWizardScreen()
                                                                                              : _section == _DashboardSection.telegramAlerts
                                                                                                  ? const TelegramAlertsScreen()
                                                                                                  : _section == _DashboardSection.hotspotTemplateInstaller
                                                                                                      ? const HotspotTemplateInstallerScreen()
                                                                                                      : const NetworkToolsScreen(),
      bottomNavigationBar: _buildNovaBottomBar(),
      ),
    );
  }

  Widget _buildNovaBottomBar() => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF070D19),
          border: Border(top: BorderSide(color: _accent.withOpacity(0.25))),
          boxShadow: [BoxShadow(color: _accent.withOpacity(0.10), blurRadius: 18, offset: const Offset(0, -5))],
        ),
        child: SafeArea(
          top: false,
          child: Row(children: [
            _NovaNavItem(icon: Icons.home_rounded, label: 'الرئيسية', selected: _section == _DashboardSection.home, onTap: () => _selectSection(_DashboardSection.home)),
            _NovaNavItem(icon: Icons.people_alt_rounded, label: 'المشتركين', selected: _section == _DashboardSection.hotspot || _section == _DashboardSection.pppoe || _section == _DashboardSection.hotspotSales, onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UnifiedActiveUsersScreen()))),
            _NovaNavItem(icon: Icons.hub_rounded, label: 'الشبكة', selected: _section == _DashboardSection.networkMap || _section == _DashboardSection.neighbors || _section == _DashboardSection.interfaces || _section == _DashboardSection.netwatch || _section == _DashboardSection.wirelessTowers || _section == _DashboardSection.liveTorch, onTap: () => _selectSection(_DashboardSection.networkMap)),
            _NovaNavItem(icon: Icons.grid_view_rounded, label: 'المزيد', selected: _section == _DashboardSection.appSettings, onTap: () => _selectSection(_DashboardSection.appSettings)),
          ]),
        ),
      );

  Widget _buildDrawer(SavedRouter? activeRouter) => Drawer(
        backgroundColor: _panel,
        child: SafeArea(
          child: ListView(padding: EdgeInsets.zero, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
              decoration: const BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [Color(0xFF123445), Color(0xFF101B27)]),
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
            _drawerItem(_DashboardSection.networkMap, Icons.account_tree_rounded, 'خريطة الشبكة'),
            _drawerItem(_DashboardSection.tools, Icons.grid_view_rounded, 'أدوات الشبكة'),
            _drawerItem(_DashboardSection.monitoring, Icons.query_stats_rounded, 'المراقبة والتحليل'),
            _drawerItem(_DashboardSection.appSettings, Icons.settings_rounded, 'الإعدادات والنظام'),
            _drawerItem(_DashboardSection.hotspot, Icons.wifi_tethering_rounded, 'الهوتسبوت'),
            _drawerItem(_DashboardSection.hotspotTemplateInstaller, Icons.web_asset_rounded, 'مولّد صفحة دخول الهوتسبوت'),
            _drawerItem(_DashboardSection.pppoe, Icons.settings_ethernet_rounded, 'مشتركو PPPoE'),
            _drawerItem(_DashboardSection.queues, Icons.speed_rounded, 'الطوابير والسرعات'),
            _drawerItem(_DashboardSection.neighbors, Icons.radar_rounded, 'كاشف الأجهزة والاتصالات'),
            _drawerItem(_DashboardSection.firewall, Icons.security_rounded, 'الشبكة والفايروول'),
            _drawerItem(_DashboardSection.dhcpBinding, Icons.devices_other_rounded, 'ربط عناوين DHCP و IP'),
            _drawerItem(_DashboardSection.system, Icons.settings_suggest_rounded, 'أدوات النظام والصيانة'),
            _drawerItem(_DashboardSection.interfaces, Icons.settings_ethernet_rounded, 'المنافذ والألياف الضوئية وVLAN'),
            _drawerItem(_DashboardSection.liveTorch, Icons.radar_rounded, 'مراقبة حركة الشبكة المباشرة'),
            _drawerItem(_DashboardSection.apiTerminal, Icons.terminal_rounded, 'وحدة أوامر API'),
            _drawerItem(_DashboardSection.netwatch, Icons.monitor_heart_outlined, 'مراقبة اتصال الإنترنت WAN'),
            _drawerItem(_DashboardSection.hotspotSales, Icons.payments_outlined, 'تقارير مبيعات الكروت'),
            _drawerItem(_DashboardSection.ipArpDns, Icons.dns_outlined, 'إدارة IP وARP وDNS'),
            _drawerItem(_DashboardSection.natAddressLists, Icons.rule_folder_outlined, 'قواعد NAT وقوائم العناوين'),
            _drawerItem(_DashboardSection.pccWizard, Icons.device_hub_outlined, 'معالج توزيع الأحمال PCC'),
            _drawerItem(_DashboardSection.bandwidthTest, Icons.speed_rounded, 'اختبار سرعة الاتصال'),
            _drawerItem(_DashboardSection.appSettings, Icons.security_rounded, 'إعدادات التطبيق والأمان'),
            _drawerItem(_DashboardSection.remoteAccess, Icons.vpn_lock_rounded, 'الوصول الخارجي والأنفاق'),
            _drawerItem(_DashboardSection.cgnatBypass, Icons.public_rounded, 'تجاوز CGNAT عبر ZeroTier وVPN'),
            _drawerItem(_DashboardSection.externalSecurity, Icons.admin_panel_settings_rounded, 'الأمان الخارجي وتحويل المنافذ'),
            _drawerItem(_DashboardSection.wirelessTowers, Icons.cell_tower_rounded, 'الصحون والأبراج اللاسلكية'),
            _drawerItem(_DashboardSection.rawQosWizard, Icons.shield_rounded, 'حماية RAW وأولوية Ping وDNS'),
            _drawerItem(_DashboardSection.telegramAlerts, Icons.telegram, 'تنبيهات Telegram من الراوتر'),
            const SizedBox(height: 12),
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
      case _DashboardSection.home: return 'الرئيسية';
      case _DashboardSection.networkMap: return 'خريطة الشبكة';
      case _DashboardSection.tools: return 'أدوات الشبكة';
      case _DashboardSection.monitoring: return 'المراقبة والتحليل';
      case _DashboardSection.appSettings: return 'الإعدادات والنظام';
      case _DashboardSection.hotspot: return 'الهوتسبوت';
      case _DashboardSection.pppoe: return 'مشتركو PPPoE';
      case _DashboardSection.queues: return 'الطوابير والسرعات';
      case _DashboardSection.neighbors: return 'كاشف الأجهزة والاتصالات';
      case _DashboardSection.firewall: return 'الشبكة والفايروول';
      case _DashboardSection.dhcpBinding: return 'ربط عناوين DHCP و IP';
      case _DashboardSection.system: return 'أدوات النظام والصيانة';
      case _DashboardSection.interfaces: return 'المنافذ والألياف الضوئية وVLAN';
      case _DashboardSection.liveTorch: return 'مراقبة حركة الشبكة المباشرة';
      case _DashboardSection.apiTerminal: return 'وحدة أوامر API';
      case _DashboardSection.netwatch: return 'مراقبة اتصال الإنترنت WAN';
      case _DashboardSection.hotspotSales: return 'تقارير مبيعات الكروت';
      case _DashboardSection.ipArpDns: return 'إدارة IP وARP وDNS';
      case _DashboardSection.natAddressLists: return 'قواعد NAT وقوائم العناوين';
      case _DashboardSection.pccWizard: return 'معالج توزيع الأحمال PCC';
      case _DashboardSection.bandwidthTest: return 'اختبار سرعة الاتصال';
      case _DashboardSection.appSettings: return 'إعدادات التطبيق والأمان';
      case _DashboardSection.remoteAccess: return 'الوصول الخارجي والأنفاق';
      case _DashboardSection.cgnatBypass: return 'تجاوز CGNAT عبر ZeroTier وVPN';
      case _DashboardSection.externalSecurity: return 'الأمان الخارجي وتحويل المنافذ';
      case _DashboardSection.wirelessTowers: return 'الصحون والأبراج اللاسلكية';
      case _DashboardSection.rawQosWizard: return 'حماية RAW وأولوية Ping وDNS';
      case _DashboardSection.telegramAlerts: return 'تنبيهات Telegram من الراوتر';
      case _DashboardSection.hotspotTemplateInstaller: return 'مولّد صفحة دخول الهوتسبوت';
    }
  }

  Widget _buildHome() => StreamBuilder<DashboardSnapshot>(
    stream: _snapshotStream,
    builder: (context, snapshot) {
      if (!snapshot.hasData && !snapshot.hasError) return const Center(child: CircularProgressIndicator(color: _accent));
      if (snapshot.hasError) return _CenteredMessage(icon: Icons.cloud_off_rounded, title: 'تعذّر قراءة موارد الراوتر', message: _friendlyError(snapshot.error!));
      final data = snapshot.data!;
      final resource = data.resource;
      final health = data.health;
      final cpu = _number(resource['cpu-load']);
      final totalMemory = _number(resource['total-memory']) ?? 0;
      final freeMemory = _number(resource['free-memory']) ?? 0;
      final usedMemory = math.max(0.0, totalMemory - freeMemory).toDouble();
      final ramPercent = totalMemory > 0 ? (usedMemory / totalMemory) * 100 : null;
      final temperature = _firstNonEmpty([health['cpu-temperature'], health['temperature'], health['board-temperature1'], health['board-temperature'], resource['cpu-temperature'], resource['temperature']]);
      final voltage = _firstNonEmpty([health['voltage'], resource['voltage']]);
      final visibleInterfaces = _interfaces.take(3).toList(growable: false);
      final host = ref.read(activeRouterDetailsProvider)?.host ?? '';
      return RefreshIndicator(
        color: _accent, backgroundColor: _panel,
        onRefresh: () async { if (_client != null) await _loadInterfaces(_client!); },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(13, 2, 13, 18),
          children: [
            _ConnectionStatusPill(identity: data.identity, host: host, online: data.error == null),
            const SizedBox(height: 5),
            _NovaCoreHero(identity: data.identity, boardName: data.boardName, version: data.version, host: host, degraded: data.error != null, uptime: resource['uptime'] ?? '—', cpuCount: resource['cpu-count'] ?? '—', architecture: resource['architecture-name'] ?? resource['architecture'] ?? '—'),
            const SizedBox(height: 7),
            LayoutBuilder(builder: (context, constraints) => GridView.count(
              crossAxisCount: 4, crossAxisSpacing: 7, mainAxisSpacing: 7,
              childAspectRatio: constraints.maxWidth < 350 ? .68 : .76,
              shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
              children: [
                _NovaMetricTile(title: 'CPU', value: cpu == null ? '—' : cpu.toStringAsFixed(0) + '%', icon: Icons.memory_rounded, color: const Color(0xFF00D9FF), progress: cpu == null ? null : cpu / 100),
                _NovaMetricTile(title: 'RAM', value: ramPercent == null ? '—' : ramPercent.toStringAsFixed(0) + '%', icon: Icons.storage_rounded, color: const Color(0xFFB76BFF), progress: ramPercent == null ? null : ramPercent / 100),
                _NovaMetricTile(title: 'حرارة', value: _formatSensor(temperature, '°C'), icon: Icons.thermostat_rounded, color: const Color(0xFFFF627D)),
                _NovaMetricTile(title: 'الجهد', value: _formatSensor(voltage, 'V'), icon: Icons.bolt_rounded, color: const Color(0xFF9BFF59)),
              ],
            )),
            if (data.error != null) ...[
              const SizedBox(height: 8),
              _NoticeBanner(color: _danger, icon: Icons.warning_amber_rounded, text: 'تعذر تحديث بعض القراءات: ' + data.error!),
            ],
            const SizedBox(height: 9),
            _buildHomeTrafficCard(),
            const SizedBox(height: 9),
            Row(children: [
              const Expanded(child: Text('اتصالات الإنترنت', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900))),
              TextButton(onPressed: () => _selectSection(_DashboardSection.networkMap), child: const Text('خريطة الشبكة', style: TextStyle(fontSize: 10))),
            ]),
            if (_loadingInterfaces)
              const LinearProgressIndicator(color: _accent, backgroundColor: _panel)
            else if (_interfaceError != null && _interfaces.isEmpty)
              _NoticeBanner(color: _danger, icon: Icons.error_outline_rounded, text: _interfaceError!)
            else if (visibleInterfaces.isEmpty)
              const _NoticeBanner(color: _muted, icon: Icons.info_outline_rounded, text: 'لا توجد واجهات لعرضها.')
            else
              Row(children: [
                for (var i = 0; i < visibleInterfaces.length; i++) ...[
                  if (i > 0) const SizedBox(width: 7),
                  Expanded(child: _NovaInterfaceTile(name: visibleInterfaces[i].name, running: visibleInterfaces[i].running, selected: visibleInterfaces[i].name == _selectedInterface, onTap: () => _selectInterface(visibleInterfaces[i].name))),
                ],
              ]),
          ],
        ),
      );
    },
  );

  Widget _buildHomeTrafficCard() {
    final rx = _hasTrafficSample ? _currentRxMbps : null;
    final tx = _hasTrafficSample ? _currentTxMbps : null;
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 10, 13, 3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [Color(0xFF10284C), Color(0xFF07132B), Color(0xFF050B1B)]),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: const Color(0xFF168BFF).withOpacity(.65)),
        boxShadow: [BoxShadow(color: const Color(0xFF0077FF).withOpacity(.18), blurRadius: 18), BoxShadow(color: const Color(0xFFB026FF).withOpacity(.08), blurRadius: 20, offset: const Offset(-5, 8))],
      ),
      child: Column(children: [
        const Text('حركة الشبكة الآن', style: TextStyle(color: Color(0xFFE4F1FF), fontSize: 13, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(child: Row(children: [
            const Icon(Icons.south_rounded, color: Color(0xFF00E676), size: 22),
            const SizedBox(width: 4),
            Expanded(child: Text(rx == null ? '— Mbps' : _formatMbps(rx), maxLines: 1, style: const TextStyle(color: Color(0xFF32FF7E), fontSize: 17, fontWeight: FontWeight.w900), textDirection: TextDirection.ltr)),
          ])),
          Expanded(child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            const Icon(Icons.north_rounded, color: Color(0xFF18FFFF), size: 22),
            const SizedBox(width: 4),
            Flexible(child: Text(tx == null ? '— Mbps' : _formatMbps(tx), maxLines: 1, style: const TextStyle(color: Color(0xFF18FFFF), fontSize: 17, fontWeight: FontWeight.w900), textDirection: TextDirection.ltr)),
          ])),
        ]),
        SizedBox(height: 55, child: _rxSpots.length < 2 ? const Center(child: Text('في انتظار بيانات حركة الشبكة...', style: TextStyle(color: _muted, fontSize: 9))) : _buildCompactTrafficChart()),
      ]),
    );
  }

  Widget _buildCompactTrafficChart() {
    final maxY = <double>[..._rxSpots.map((e) => e.y), ..._txSpots.map((e) => e.y)].fold<double>(5, (a, b) => math.max(a, b)).clamp(5, double.infinity).toDouble();
    final lastX = _rxSpots.last.x;
    final minX = math.max(0, lastX - 24).toDouble();
    return LineChart(LineChartData(
      minX: minX, maxX: math.max(minX + 1, lastX), minY: 0, maxY: maxY * 1.12,
      gridData: const FlGridData(show: false), titlesData: const FlTitlesData(show: false),
      borderData: FlBorderData(show: false), lineTouchData: const LineTouchData(enabled: false),
      lineBarsData: [
        LineChartBarData(spots: _rxSpots, isCurved: true, color: const Color(0xFF00E5FF), barWidth: 2, dotData: const FlDotData(show: false), belowBarData: BarAreaData(show: true, gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x6600E5FF), Color(0x0000E5FF)]))),
        LineChartBarData(spots: _txSpots, isCurved: true, color: const Color(0xFF00E676), barWidth: 1.6, dotData: const FlDotData(show: false), belowBarData: BarAreaData(show: true, gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x4400E676), Color(0x0000E676)]))),
      ],
    ), duration: const Duration(milliseconds: 280));
  }

Widget _buildNetworkMap() => StreamBuilder<DashboardSnapshot>(
    stream: _snapshotStream,
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: _accent));
      final data = snapshot.data!;
      final active = _interfaces.where((item) => item.running).length;
      final wan = _interfaces.where((item) => RegExp(r'wan|starlink|ether[123]|sfp').hasMatch(item.name.toLowerCase())).take(2).toList();
      return ListView(padding: const EdgeInsets.fromLTRB(13, 8, 13, 20), children: [
        const Text('خريطة الشبكة', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        const Text('تصوّر الاتصال من الإنترنت إلى الراوتر ثم الشبكة الداخلية', style: TextStyle(color: _muted, fontSize: 10)),
        const SizedBox(height: 9),
        Container(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF071A37), Color(0xFF040B19)]),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF168BFF).withOpacity(.55)),
            boxShadow: [BoxShadow(color: _accent.withOpacity(.12), blurRadius: 22)],
          ),
          child: Column(children: [
            const _InternetGlobeNode(),
            const SizedBox(height: 2),
            SizedBox(height: 340, child: LayoutBuilder(builder: (context, c) => Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _ReferenceTopologyLinksPainter())),
                Positioned(left: 0, top: 25, width: c.maxWidth * .31, child: _TopologyNode(icon: Icons.satellite_alt_rounded, title: wan.isNotEmpty ? wan[0].name : 'WAN 1', subtitle: wan.isNotEmpty ? (wan[0].running ? 'متصل' : 'متوقف') : 'غير مكتشف', color: wan.isNotEmpty && wan[0].running ? _rxColor : _accent)),
                Positioned(right: 0, top: 25, width: c.maxWidth * .31, child: _TopologyNode(icon: Icons.cell_tower_rounded, title: wan.length > 1 ? wan[1].name : 'WAN 2', subtitle: wan.length > 1 ? (wan[1].running ? 'متصل' : 'متوقف') : 'غير مكتشف', color: wan.length > 1 && wan[1].running ? _rxColor : _accent)),
                Positioned(left: c.maxWidth * .32, right: c.maxWidth * .32, top: 88, child: _TopologyNode(icon: Icons.router_rounded, title: data.boardName, subtitle: 'RouterOS ' + data.version, color: _accent, featured: true)),
                Positioned(left: 0, top: 245, width: c.maxWidth * .31, child: const _TopologyNode(icon: Icons.wifi_tethering_rounded, title: 'شبكة Wi-Fi', subtitle: 'واجهات لاسلكية', color: Color(0xFF37DDF2))),
                Positioned(left: c.maxWidth * .345, right: c.maxWidth * .345, top: 245, child: const _TopologyNode(icon: Icons.dns_rounded, title: 'السويتشات', subtitle: 'Bridge / Ethernet', color: Color(0xFFB77AFF))),
                Positioned(right: 0, top: 245, width: c.maxWidth * .31, child: const _TopologyNode(icon: Icons.groups_rounded, title: 'المشتركون', subtitle: 'PPPoE / Hotspot', color: Color(0xFF37DDF2))),
                Positioned(left: 0, right: 0, bottom: 0, child: Center(child: Text(active.toString() + ' / ' + _interfaces.length.toString() + ' واجهة فعّالة', style: const TextStyle(color: Color(0xFF39E6A5), fontSize: 10, fontWeight: FontWeight.w800)))),
              ],
            ))),
            const SizedBox(height: 6),
            Text('الراوتر: ' + data.identity + '  •  ' + data.boardName, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFB9D2F4), fontSize: 10)),
          ]),
        ),
        const SizedBox(height: 12),
        _NetworkMapAction(icon: Icons.settings_ethernet_rounded, title: 'واجهات الاتصال', subtitle: 'Ethernet · Bridge · VLAN · SFP', onTap: () => _selectSection(_DashboardSection.interfaces)),
        const SizedBox(height: 8),
        _NetworkMapAction(icon: Icons.radar_rounded, title: 'الجيران والأجهزة', subtitle: 'استكشاف الأجهزة المتصلة', onTap: () => _selectSection(_DashboardSection.neighbors)),
        const SizedBox(height: 8),
        _NetworkMapAction(icon: Icons.monitor_heart_rounded, title: 'مراقبة WAN', subtitle: 'حالة الاتصال والانقطاع', onTap: () => _selectSection(_DashboardSection.netwatch)),
        const SizedBox(height: 8),
        _NetworkMapAction(icon: Icons.cell_tower_rounded, title: 'الأبراج والروابط اللاسلكية', subtitle: 'إدارة مواقع وأجهزة الربط', onTap: () => _selectSection(_DashboardSection.wirelessTowers)),
      ]);
    },
  );

Widget _buildTools() => ListView(
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 22),
    children: [
      const _SectionHeading(title: 'أدوات الشبكة المتقدمة', subtitle: 'كل أداة تفتح وظيفتها الفعلية'),
      const SizedBox(height: 14),
      GridView.count(crossAxisCount: 3, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.94, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), children: [
        _NovaQuickAction(icon: Icons.flash_on_rounded, title: 'Torch', color: const Color(0xFF36F2D0), onTap: () => _selectSection(_DashboardSection.liveTorch)),
        _NovaQuickAction(icon: Icons.route_rounded, title: 'Ping / Speed', color: _accent, onTap: () => _selectSection(_DashboardSection.bandwidthTest)),
        _NovaQuickAction(icon: Icons.hub_rounded, title: 'الجيران', color: const Color(0xFFB77AFF), onTap: () => _selectSection(_DashboardSection.neighbors)),
        _NovaQuickAction(icon: Icons.security_rounded, title: 'Firewall', color: const Color(0xFF4DABFF), onTap: () => _selectSection(_DashboardSection.firewall)),
        _NovaQuickAction(icon: Icons.wifi_tethering_rounded, title: 'Hotspot', color: const Color(0xFF37E5C0), onTap: () => _selectSection(_DashboardSection.hotspot)),
        _NovaQuickAction(icon: Icons.people_alt_rounded, title: 'PPPoE', color: const Color(0xFF5AC8FF), onTap: () => _selectSection(_DashboardSection.pppoe)),
        _NovaQuickAction(icon: Icons.dns_rounded, title: 'IP / DNS', color: const Color(0xFFB77AFF), onTap: () => _selectSection(_DashboardSection.ipArpDns)),
        _NovaQuickAction(icon: Icons.queue_rounded, title: 'Queues', color: const Color(0xFFFFB45E), onTap: () => _selectSection(_DashboardSection.queues)),
        _NovaQuickAction(icon: Icons.devices_rounded, title: 'DHCP', color: const Color(0xFF55B8FF), onTap: () => _selectSection(_DashboardSection.dhcpBinding)),
        _NovaQuickAction(icon: Icons.lan_rounded, title: 'Interfaces', color: const Color(0xFF42E6C0), onTap: () => _selectSection(_DashboardSection.interfaces)),
        _NovaQuickAction(icon: Icons.monitor_heart_rounded, title: 'WAN Watch', color: const Color(0xFFFF8EAC), onTap: () => _selectSection(_DashboardSection.netwatch)),
        _NovaQuickAction(icon: Icons.settings_suggest_rounded, title: 'System', color: const Color(0xFFFFC46B), onTap: () => _selectSection(_DashboardSection.system)),
      ]),
      const SizedBox(height: 16),
      _NetworkMapAction(icon: Icons.settings_rounded, title: 'إعدادات النظام والتطبيق', subtitle: 'الاتصال والأمان والنسخ الاحتياطي', onTap: () => _selectSection(_DashboardSection.appSettings)),
    ],
  );

  Widget _buildMonitoring() => StreamBuilder<DashboardSnapshot>(
    stream: _snapshotStream,
    builder: (context, snapshot) {
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: _accent));
      final data = snapshot.data!;
      final resource = data.resource;
      final total = _number(resource['total-memory']) ?? 0;
      final free = _number(resource['free-memory']) ?? 0;
      final ram = total > 0 ? ((total - free) / total) * 100 : null;
      final cpu = _number(resource['cpu-load']);
      final temp = _firstNonEmpty([data.health['cpu-temperature'], data.health['temperature'], data.health['board-temperature1']]);
      final interfacesUp = _interfaces.where((item) => item.running).length;
      return ListView(padding: const EdgeInsets.fromLTRB(13, 8, 13, 20), children: [
        const Text('المراقبة والتحليل', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: const Color(0xFF07152C), borderRadius: BorderRadius.circular(14), border: Border.all(color: _accent.withOpacity(.28))),
          child: Row(children: [
            _MonitorTab(label: 'السرعات', selected: _monitorTab == 0, onTap: () => setState(() => _monitorTab = 0)),
            _MonitorTab(label: 'الموارد', selected: _monitorTab == 1, onTap: () => setState(() => _monitorTab = 1)),
            _MonitorTab(label: 'الواجهات', selected: _monitorTab == 2, onTap: () => setState(() => _monitorTab = 2)),
          ]),
        ),
        const SizedBox(height: 12),
        if (_monitorTab == 0) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF0B1A35), Color(0xFF050C1C)]), borderRadius: BorderRadius.circular(18), border: Border.all(color: _accent.withOpacity(.3))),
            child: Column(children: [
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _LegendDot(color: Color(0xFF00E5FF), label: 'تحميل'),
                SizedBox(width: 22),
                _LegendDot(color: Color(0xFFB026FF), label: 'رفع'),
              ]),
              const SizedBox(height: 8),
              SizedBox(height: 190, child: _rxSpots.length < 2 ? const Center(child: Text('اختر واجهة من الرئيسية لبدء القياس', style: TextStyle(color: _muted, fontSize: 11))) : _buildLineChart()),
            ]),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _NovaGauge(value: cpu, label: 'CPU', color: _accent, suffix: '%')),
            Expanded(child: _NovaGauge(value: ram, label: 'RAM', color: const Color(0xFFB76BFF), suffix: '%')),
            Expanded(child: _NovaGauge(value: _number(temp), label: 'الحرارة', color: const Color(0xFFFF405F), suffix: '°C')),
          ]),
          const SizedBox(height: 12),
          _NetworkMapAction(icon: Icons.speed_rounded, title: 'الترافيك الحالي', subtitle: 'RX ' + (_hasTrafficSample ? _formatMbps(_currentRxMbps) : '—') + '  •  TX ' + (_hasTrafficSample ? _formatMbps(_currentTxMbps) : '—'), onTap: () => setState(() => _monitorTab = 0)),
        ] else if (_monitorTab == 1) ...[
          GridView.count(crossAxisCount: 3, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: .85, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), children: [
            _NovaMetricTile(title: 'CPU', value: cpu == null ? '—' : cpu.toStringAsFixed(0) + '%', icon: Icons.memory_rounded, color: _accent, progress: cpu == null ? null : cpu / 100),
            _NovaMetricTile(title: 'RAM', value: ram == null ? '—' : ram.toStringAsFixed(0) + '%', icon: Icons.storage_rounded, color: const Color(0xFFB76BFF), progress: ram == null ? null : ram / 100),
            _NovaMetricTile(title: 'الحرارة', value: _formatSensor(temp, '°C'), icon: Icons.thermostat_rounded, color: const Color(0xFFFF627D)),
          ]),
          const SizedBox(height: 12),
          _NetworkMapAction(icon: Icons.memory_rounded, title: 'الذاكرة الحرة', subtitle: (resource['free-memory'] ?? '—') + ' / ' + (resource['total-memory'] ?? '—'), onTap: () => setState(() => _monitorTab = 1)),
        ] else ...[
          Row(children: [
            Expanded(child: _NovaMetricTile(title: 'واجهات فعّالة', value: interfacesUp.toString(), icon: Icons.lan_rounded, color: _rxColor)),
            const SizedBox(width: 8),
            Expanded(child: _NovaMetricTile(title: 'إجمالي الواجهات', value: _interfaces.length.toString(), icon: Icons.device_hub_rounded, color: _accent)),
          ]),
          const SizedBox(height: 12),
          ..._interfaces.map((item) => _NetworkMapAction(icon: Icons.settings_ethernet_rounded, title: item.name, subtitle: item.running ? 'متصل • ' + item.type : item.disabled ? 'معطّل • ' + item.type : 'غير متصل • ' + item.type, onTap: () => _selectSection(_DashboardSection.interfaces))),
        ],
      ]);
    },
  );

  Widget _buildReferenceSettings() => ListView(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
    children: [
      Container(
        height: 188,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const RadialGradient(center: Alignment(.5, .25), radius: 1.05, colors: [Color(0xFF123C6D), Color(0xFF07142B), Color(0xFF030814)]),
          border: Border.all(color: _accent.withOpacity(.3)),
          boxShadow: [BoxShadow(color: _accent.withOpacity(.13), blurRadius: 24)],
        ),
        child: Stack(children: [
          const Positioned.fill(child: CustomPaint(painter: _NovaBrandOrbitPainter())),
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            ShaderMask(shaderCallback: (bounds) => const LinearGradient(colors: [Color(0xFF7DF9FF), Color(0xFF00D2FF), Color(0xFF0077FF)]).createShader(bounds), child: const Text('N', style: TextStyle(color: Colors.white, fontSize: 58, fontWeight: FontWeight.w900, height: .95))),
            const SizedBox(height: 3),
            const Text('NOVA', style: TextStyle(color: Color(0xFF00D9FF), fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 3, shadows: [Shadow(color: _accent, blurRadius: 18)])),
            const Text('Power. Control. Freedom.', textDirection: TextDirection.ltr, style: TextStyle(color: Color(0xFFD8E8FF), fontSize: 10, fontWeight: FontWeight.w600)),
          ])),
        ]),
      ),
      const SizedBox(height: 14),
      _NetworkMapAction(icon: Icons.wifi_rounded, title: 'إعدادات الاتصال', subtitle: 'إدارة اتصال الراوتر والواجهات', onTap: () => _selectSection(_DashboardSection.interfaces)),
      const SizedBox(height: 8),
      _NetworkMapAction(icon: Icons.lock_rounded, title: 'الأمان والصلاحيات', subtitle: 'إعدادات الحماية والوصول الخارجي', onTap: () => _selectSection(_DashboardSection.externalSecurity)),
      const SizedBox(height: 8),
      _NetworkMapAction(icon: Icons.backup_rounded, title: 'النسخ الاحتياطي والاستعادة', subtitle: 'نسخ إعدادات الراوتر وصيانتها', onTap: () => _selectSection(_DashboardSection.system)),
      const SizedBox(height: 8),
      _NetworkMapAction(icon: Icons.cloud_download_rounded, title: 'التحديثات', subtitle: 'إدارة النظام والتحديثات المتاحة', onTap: () => _selectSection(_DashboardSection.system)),
      const SizedBox(height: 8),
      _NetworkMapAction(icon: Icons.info_outline_rounded, title: 'حول التطبيق', subtitle: 'NOVA Router Manager', onTap: () => showAboutDialog(context: context, applicationName: 'NOVA Router Manager', applicationVersion: '1.0.0', applicationLegalese: 'Power. Control. Freedom.')),
      const SizedBox(height: 18),
      Center(child: SizedBox(width: 230, child: FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF641A9B), foregroundColor: Colors.white, side: const BorderSide(color: Color(0xFFD500F9)), elevation: 8, shadowColor: const Color(0xFFD500F9)),
        onPressed: _disconnect, icon: const Icon(Icons.power_settings_new_rounded), label: const Text('تسجيل الخروج', style: TextStyle(fontWeight: FontWeight.w900)),
      ))),
    ],
  );

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
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_rxColor.withOpacity(0.28), _rxColor.withOpacity(0.015)]),
            ),
          ),
          LineChartBarData(
            spots: _txSpots,
            isCurved: true,
            curveSmoothness: 0.18,
            color: _txColor,
            barWidth: 2.3,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [_txColor.withOpacity(0.20), _txColor.withOpacity(0.01)]),
            ),
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

class _ConnectionStatusPill extends StatelessWidget {
  const _ConnectionStatusPill({required this.identity, required this.host, required this.online});
  final String identity; final String host; final bool online;
  @override
  Widget build(BuildContext context) {
    final color = online ? const Color(0xFF39E6A5) : _danger;
    return Center(child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
      decoration: BoxDecoration(color: color.withOpacity(0.10), borderRadius: BorderRadius.circular(30), border: Border.all(color: color.withOpacity(0.48)), boxShadow: [BoxShadow(color: color.withOpacity(0.13), blurRadius: 15)]),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(online ? Icons.check_circle_rounded : Icons.error_rounded, color: color, size: 14), const SizedBox(width: 7),
        Text(online ? 'متصل بالراوتر' : 'الاتصال يحتاج مراجعة', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w900)),
        if (host.isNotEmpty) ...[const SizedBox(width: 7), Container(width: 3, height: 3, decoration: BoxDecoration(color: color, shape: BoxShape.circle)), const SizedBox(width: 7), Text(host, textDirection: TextDirection.ltr, style: TextStyle(color: color.withOpacity(0.85), fontSize: 9))],
      ]),
    ));
  }
}

class _NetworkMapAction extends StatelessWidget {
  const _NetworkMapAction({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon; final String title; final String subtitle; final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(color: const Color(0xFF0A1729), borderRadius: BorderRadius.circular(16), child: InkWell(
    borderRadius: BorderRadius.circular(16), onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: _accent.withOpacity(0.22))),
      child: Row(children: [
        Container(width: 37, height: 37, decoration: BoxDecoration(color: _accent.withOpacity(0.10), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: _accent, size: 19)),
        const SizedBox(width: 11),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 3), Text(subtitle, style: const TextStyle(color: _muted, fontSize: 9)),
        ])),
        const Icon(Icons.chevron_left_rounded, color: _muted, size: 18),
      ]),
    ),
  ));
}

class _NovaMetricTile extends StatelessWidget {
  const _NovaMetricTile({required this.title, required this.value, required this.icon, required this.color, this.progress});
  final String title, value;
  final IconData icon;
  final Color color;
  final double? progress;

  @override
  Widget build(BuildContext context) => Container(
    height: 116,
    padding: const EdgeInsets.fromLTRB(9, 11, 9, 9),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withOpacity(0.13), const Color(0xFF0A1220), const Color(0xFF080E18)],
      ),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: color.withOpacity(0.32)),
      boxShadow: [
        BoxShadow(color: color.withOpacity(0.10), blurRadius: 18, spreadRadius: -5),
        const BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 5)),
      ],
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(
          width: 29, height: 29,
          decoration: BoxDecoration(
            color: color.withOpacity(0.13),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.24)),
          ),
          child: Icon(icon, color: color, size: 17),
        ),
        const Spacer(),
        Container(width: 5, height: 5, decoration: BoxDecoration(color: color, shape: BoxShape.circle, boxShadow: [BoxShadow(color: color.withOpacity(0.7), blurRadius: 7)])),
      ]),
      const Spacer(),
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFF9AABC2), fontSize: 9, fontWeight: FontWeight.w700)),
      const SizedBox(height: 3),
      FittedBox(fit: BoxFit.scaleDown, child: Text(value,
        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w900,
          shadows: [Shadow(color: color.withOpacity(0.48), blurRadius: 10)]))),
      const SizedBox(height: 7),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: progress == null
            ? Container(height: 3, color: Colors.white.withOpacity(0.07))
            : LinearProgressIndicator(
                value: progress!.clamp(0.0, 1.0).toDouble(),
                minHeight: 3,
                backgroundColor: Colors.white.withOpacity(0.07),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
      ),
    ]),
  );
}

class _NovaInterfaceTile extends StatelessWidget {
  const _NovaInterfaceTile({required this.name, required this.running, required this.selected, required this.onTap});
  final String name;
  final bool running, selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
        decoration: BoxDecoration(
          color: const Color(0xFF0B1628),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? _accent : (running ? _rxColor.withOpacity(0.4) : Colors.white12)),
          boxShadow: selected ? [BoxShadow(color: _accent.withOpacity(0.14), blurRadius: 12)] : null,
        ),
        child: Column(children: [
          Icon(Icons.language_rounded, color: running ? _rxColor : _muted, size: 20),
          const SizedBox(height: 5),
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, textDirection: TextDirection.ltr, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(running ? 'متصل' : 'متوقف', style: TextStyle(color: running ? _rxColor : _danger, fontSize: 9, fontWeight: FontWeight.w800)),
        ]),
      ),
    ),
  );
}

class _NovaQuickAction extends StatelessWidget {
  const _NovaQuickAction({required this.icon, required this.title, required this.color, required this.onTap});
  final IconData icon;
  final String title;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF15253B), Color(0xFF0A1220), Color(0xFF080D16)],
          ),
          border: Border.all(color: color.withOpacity(0.25)),
          boxShadow: [BoxShadow(color: color.withOpacity(0.07), blurRadius: 16, spreadRadius: -4)],
        ),
        child: Stack(children: [
          Positioned(top: -18, right: -16, child: Container(
            width: 58, height: 58,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(0.055)),
          )),
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 43, height: 43,
              decoration: BoxDecoration(
                color: color.withOpacity(0.11),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withOpacity(0.25)),
                boxShadow: [BoxShadow(color: color.withOpacity(0.10), blurRadius: 12)],
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(height: 8),
            Text(title, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFFE5F0FC), fontSize: 9, fontWeight: FontWeight.w800)),
          ])),
        ]),
      ),
    ),
  );
}

class _NovaNavItem extends StatelessWidget {
  const _NovaNavItem({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 190),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: selected ? _accent.withOpacity(0.10) : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? _accent.withOpacity(0.22) : Colors.transparent),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: selected ? _accent : const Color(0xFF8194B0), size: 21),
            const SizedBox(height: 3),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: selected ? _accent : const Color(0xFF8194B0), fontSize: 9,
                fontWeight: selected ? FontWeight.w900 : FontWeight.w600)),
            const SizedBox(height: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 190),
              width: selected ? 15 : 4,
              height: 2,
              decoration: BoxDecoration(color: selected ? _accent : Colors.transparent, borderRadius: BorderRadius.circular(4)),
            ),
          ]),
        ),
      ),
    ),
  );
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

class _TrafficValue extends StatelessWidget {
  const _TrafficValue({required this.label, required this.value, required this.color});
  final String label;
  final String value;
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
            Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w900)),
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

class _HudTag extends StatelessWidget {
  const _HudTag({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF06111D).withOpacity(0.82),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.42)),
          boxShadow: [
            BoxShadow(color: color.withOpacity(0.12), blurRadius: 12),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color, size: 11),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 8,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.7,
              ),
            ),
          ]),
        ),
      );
}

class _NovaCoreHero extends StatelessWidget {
  const _NovaCoreHero({required this.identity, required this.boardName, required this.version, required this.host, required this.degraded, required this.uptime, required this.cpuCount, required this.architecture});
  final String identity, boardName, version, host, uptime, cpuCount, architecture;
  final bool degraded;

  @override
  Widget build(BuildContext context) {
    final status = degraded ? _danger : _rxColor;
    return SizedBox(
      height: 188,
      child: Stack(children: [
        Positioned.fill(child: CustomPaint(painter: const _ReferenceRouterHeroPainter())),
        Positioned(top: 4, right: 6, child: Text('NOVA  /  NETWORK CORE', textDirection: TextDirection.ltr, style: TextStyle(color: _accent.withOpacity(.7), fontSize: 7, fontWeight: FontWeight.w900, letterSpacing: 1.2))),
        Positioned(left: 5, top: 6, child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: status, shape: BoxShape.circle, boxShadow: [BoxShadow(color: status.withOpacity(.8), blurRadius: 7)])),
          const SizedBox(width: 5),
          Text(degraded ? 'TELEMETRY WARNING' : 'CORE ONLINE', textDirection: TextDirection.ltr, style: TextStyle(color: status, fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: .6)),
        ])),
        Positioned(bottom: 4, left: 0, right: 0, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(boardName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w900, shadows: [Shadow(color: _accent, blurRadius: 10)])),
          const SizedBox(height: 2),
          Text(identity + '  •  RouterOS ' + version, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF9DB8D8), fontSize: 8, fontWeight: FontWeight.w600)),
        ])),
      ]),
    );
  }
}

class _ReferenceRouterHeroPainter extends CustomPainter {
  const _ReferenceRouterHeroPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 346, size.height / 182);
    final glow = Paint()..shader = const RadialGradient(colors: [Color(0x6600E5FF), Color(0x226A00FF), Colors.transparent]).createShader(const Rect.fromLTWH(8, 24, 330, 150));
    canvas.drawOval(const Rect.fromLTWH(8, 28, 330, 150), glow);
    const dots = <Offset>[
      Offset(55,40),Offset(62,42),Offset(70,38),Offset(78,45),Offset(85,50),
      Offset(145,30),Offset(155,34),Offset(165,30),Offset(175,36),Offset(185,32),
      Offset(235,36),Offset(245,40),Offset(255,35),Offset(265,42),Offset(275,48),Offset(285,44),
      Offset(95,65),Offset(102,72),Offset(220,62),Offset(230,68),
    ];
    final dot = Paint()..color = const Color(0x7700D2FF);
    for (final p in dots) { canvas.drawCircle(p, 1.5, dot); }
    final ring = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.4..color = const Color(0x99B026FF);
    canvas.drawOval(const Rect.fromLTWH(38, 122, 270, 48), ring);
    ring.color = const Color(0xCC00E5FF); ring.strokeWidth = 2;
    canvas.drawOval(const Rect.fromLTWH(61, 128, 224, 36), ring);
    ring.color = const Color(0x997DF9FF); ring.strokeWidth = 1;
    canvas.drawOval(const Rect.fromLTWH(87, 133, 172, 25), ring);
    final antenna = Paint()..color = const Color(0xFF00E5FF)..strokeWidth = 2.2..strokeCap = StrokeCap.round;
    const antennaData = <List<double>>[[110,34,110,91],[150,25,150,86],[194,27,194,87],[230,36,230,91]];
    for (final a in antennaData) {
      canvas.drawLine(Offset(a[0],a[1]),Offset(a[2],a[3]),antenna);
      canvas.drawCircle(Offset(a[0],a[1]),3,Paint()..color=const Color(0xFFFFAB00));
    }
    final top = Path()..moveTo(84,96)..lineTo(142,74)..lineTo(256,84)..lineTo(212,112)..close();
    final front = Path()..moveTo(84,96)..lineTo(212,112)..lineTo(212,138)..lineTo(84,122)..close();
    final side = Path()..moveTo(212,112)..lineTo(256,84)..lineTo(256,108)..lineTo(212,138)..close();
    final shellGlow = Paint()..color=const Color(0x9900DFFF)..style=PaintingStyle.stroke..strokeWidth=5..maskFilter=const MaskFilter.blur(BlurStyle.normal,8);
    canvas.drawPath(top,shellGlow);canvas.drawPath(front,shellGlow);canvas.drawPath(side,shellGlow);
    canvas.drawPath(top,Paint()..shader=const LinearGradient(colors:[Color(0xFF1B3568),Color(0xFF0A1736),Color(0xFF060D24)]).createShader(const Rect.fromLTWH(84,74,172,64)));
    canvas.drawPath(front,Paint()..color=const Color(0xFF07112A));
    canvas.drawPath(side,Paint()..color=const Color(0xFF0D1F49));
    final edge=Paint()..color=const Color(0xFF00E5FF)..style=PaintingStyle.stroke..strokeWidth=1.7;
    canvas.drawPath(top,edge);canvas.drawPath(front,edge);canvas.drawPath(side,edge);
    final bezel=Path()..moveTo(92,103)..lineTo(204,117)..lineTo(204,132)..lineTo(92,118)..close();
    canvas.drawPath(bezel,Paint()..color=const Color(0xFF040918));
    canvas.drawPath(bezel,Paint()..color=const Color(0x8800E5FF)..style=PaintingStyle.stroke..strokeWidth=.8);
    final label=TextPainter(text:const TextSpan(text:'MikroTik',style:TextStyle(color:Colors.white,fontSize:13,fontWeight:FontWeight.w800,letterSpacing:.4)),textDirection:TextDirection.ltr)..layout();
    label.paint(canvas,const Offset(121,108));
    for(var i=0;i<3;i++){canvas.drawCircle(Offset(184+i*7,123+i*.5),2.2,Paint()..color=i==1?const Color(0xFF00E676):const Color(0xFF00E5FF));}
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ReferenceRouterHeroPainter oldDelegate) => false;
}

class _InternetGlobeNode extends StatelessWidget {
  const _InternetGlobeNode();
  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
    Container(width: 82, height: 82, decoration: BoxDecoration(shape: BoxShape.circle, gradient: const RadialGradient(colors: [Color(0xFF164E91), Color(0xFF071B3B), Color(0xFF040B1B)]), border: Border.all(color: const Color(0xFF00E5FF), width: 1.4), boxShadow: const [BoxShadow(color: Color(0x8800BFFF), blurRadius: 22), BoxShadow(color: Color(0x557B2CFF), blurRadius: 30)]), child: const Icon(Icons.public_rounded, color: Color(0xFF54E9FF), size: 49)),
    const SizedBox(height: 4),
    const Text('الإنترنت', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w900, shadows: [Shadow(color: _accent, blurRadius: 9)])),
  ]);
}

class _TopologyNode extends StatelessWidget {
  const _TopologyNode({required this.icon, required this.title, required this.subtitle, required this.color, this.featured = false});
  final IconData icon; final String title, subtitle; final Color color; final bool featured;
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: 5, vertical: featured ? 12 : 9),
    decoration: BoxDecoration(
      gradient: LinearGradient(begin: Alignment.topCenter,end: Alignment.bottomCenter,colors: [color.withOpacity(.19),const Color(0xFF071225)]),
      borderRadius: BorderRadius.circular(featured ? 17 : 14),
      border: Border.all(color: color.withOpacity(featured ? .8 : .42),width: featured ? 1.5 : 1),
      boxShadow: [BoxShadow(color: color.withOpacity(.13),blurRadius: featured ? 18 : 10)],
    ),
    child: Column(mainAxisSize: MainAxisSize.min,children:[
      Icon(icon,color:color,size:featured ? 31 : 27),
      const SizedBox(height:5),
      Text(title,textAlign:TextAlign.center,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:Colors.white,fontSize:featured ? 10 : 9,fontWeight:FontWeight.w900)),
      const SizedBox(height:2),
      Text(subtitle,textAlign:TextAlign.center,maxLines:1,overflow:TextOverflow.ellipsis,style:TextStyle(color:color,fontSize:8,fontWeight:FontWeight.w700)),
    ]),
  );
}

class _ReferenceTopologyLinksPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final glow=Paint()..color=const Color(0x7700CFFF)..strokeWidth=4..maskFilter=const MaskFilter.blur(BlurStyle.normal,5);
    final line=Paint()..color=const Color(0xCC00DFFF)..strokeWidth=1.3..style=PaintingStyle.stroke;
    final center=size.width/2;
    final paths=<Path>[
      Path()..moveTo(center,0)..cubicTo(center*.8,22,size.width*.22,12,size.width*.155,62),
      Path()..moveTo(center,0)..cubicTo(center*1.2,22,size.width*.78,12,size.width*.845,62),
      Path()..moveTo(center,0)..lineTo(center,105),
      Path()..moveTo(center,177)..cubicTo(center*.8,205,size.width*.22,205,size.width*.155,250),
      Path()..moveTo(center,177)..lineTo(center,250),
      Path()..moveTo(center,177)..cubicTo(center*1.2,205,size.width*.78,205,size.width*.845,250),
    ];
    for(final p in paths){canvas.drawPath(p,glow);canvas.drawPath(p,line);}
    for(final p in [Offset(center,0),Offset(size.width*.155,62),Offset(size.width*.845,62),Offset(center,177),Offset(size.width*.155,250),Offset(center,250),Offset(size.width*.845,250)]){
      canvas.drawCircle(p,3,Paint()..color=const Color(0xFF7DF9FF)..maskFilter=const MaskFilter.blur(BlurStyle.normal,4));
    }
  }
  @override
  bool shouldRepaint(covariant _ReferenceTopologyLinksPainter oldDelegate)=>false;
}

class _MonitorTab extends StatelessWidget {
  const _MonitorTab({required this.label,required this.selected,required this.onTap});
  final String label;final bool selected;final VoidCallback onTap;
  @override
  Widget build(BuildContext context)=>Expanded(child:GestureDetector(onTap:onTap,child:AnimatedContainer(duration:const Duration(milliseconds:180),padding:const EdgeInsets.symmetric(vertical:9),decoration:BoxDecoration(gradient:selected?const LinearGradient(colors:[Color(0xFF00C6FF),Color(0xFF0066FF)]):null,borderRadius:BorderRadius.circular(10),boxShadow:selected?[const BoxShadow(color:Color(0x7700A2FF),blurRadius:12)]:null),child:Text(label,textAlign:TextAlign.center,style:TextStyle(color:selected?Colors.white:const Color(0xFFB0C8E8),fontSize:11,fontWeight:selected?FontWeight.w900:FontWeight.w700)))));
}

class _NovaGauge extends StatelessWidget {
  const _NovaGauge({required this.value,required this.label,required this.color,required this.suffix});
  final double? value;final String label,suffix;final Color color;
  @override
  Widget build(BuildContext context)=>SizedBox(height:92,child:Column(children:[
    SizedBox(width:90,height:61,child:Stack(alignment:Alignment.center,children:[
      Positioned.fill(child:CustomPaint(painter:_NovaGaugePainter(progress:value==null?null:(value!/100).clamp(0,1),color:color))),
      Positioned(top:28,child:Text(value==null?'—':value!.toStringAsFixed(0)+suffix,style:const TextStyle(color:Colors.white,fontSize:13,fontWeight:FontWeight.w900))),
    ])),
    Text(label,style:TextStyle(color:color,fontSize:10,fontWeight:FontWeight.w900)),
  ]));
}

class _NovaGaugePainter extends CustomPainter {
  const _NovaGaugePainter({required this.progress,required this.color});
  final double? progress;final Color color;
  @override
  void paint(Canvas canvas,Size size){
    final rect=Rect.fromLTWH(8,5,size.width-16,(size.height*2)-10);
    final bg=Paint()..color=Colors.white.withOpacity(.09)..style=PaintingStyle.stroke..strokeWidth=6..strokeCap=StrokeCap.round;
    canvas.drawArc(rect,math.pi,math.pi,false,bg);
    if(progress!=null){final p=Paint()..color=color..style=PaintingStyle.stroke..strokeWidth=6..strokeCap=StrokeCap.round..maskFilter=const MaskFilter.blur(BlurStyle.normal,2);canvas.drawArc(rect,math.pi,math.pi*progress!,false,p);}
  }
  @override
  bool shouldRepaint(covariant _NovaGaugePainter old)=>old.progress!=progress||old.color!=color;
}

class _NovaBrandOrbitPainter extends CustomPainter {
  const _NovaBrandOrbitPainter();
  @override
  void paint(Canvas canvas,Size size){
    final center=Offset(size.width/2,size.height*.58);
    for(var i=0;i<5;i++){final p=Paint()..color=(i.isEven?const Color(0x7700E5FF):const Color(0x667B2CFF)).withOpacity(.30-i*.035)..style=PaintingStyle.stroke..strokeWidth=1;canvas.drawOval(Rect.fromCenter(center:center,width:size.width*(.40+i*.16),height:18+i*8),p);}
    final glow=Paint()..shader=RadialGradient(colors:[const Color(0x5500CFFF),Colors.transparent]).createShader(Rect.fromCircle(center:center,radius:size.width*.55));canvas.drawCircle(center,size.width*.55,glow);
  }
  @override
  bool shouldRepaint(covariant _NovaBrandOrbitPainter old)=>false;
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
