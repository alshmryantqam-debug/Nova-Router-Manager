
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';
import '../../core/storage/router_storage_service.dart';
import '../settings/app_settings_screen.dart';

const Color _bg = Color(0xFF080B12);
const Color _panel = Color(0xFF111722);
const Color _muted = Color(0xFF8D9AB0);
const Color _accent = Color(0xFF8B7CFF);
const Color _green = Color(0xFF43D9A3);
const Color _red = Color(0xFFFF657A);

class RouterListScreen extends ConsumerStatefulWidget {
  const RouterListScreen({super.key});

  @override
  ConsumerState<RouterListScreen> createState() => _RouterListScreenState();
}

class _RouterListScreenState extends ConsumerState<RouterListScreen> {
  final Map<String, _PingStatus> _pings = {};
  Timer? _timer;
  bool _refreshing = false;
  bool _refreshQueued = false;
  String? _connectingId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_refreshPings());
      _timer = Timer.periodic(const Duration(seconds: 15), (_) {
        unawaited(_refreshPings());
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refreshPings() async {
    if (!mounted) return;
    if (_refreshing) {
      _refreshQueued = true;
      return;
    }
    final routers = ref.read(savedRoutersProvider).valueOrNull;
    if (routers == null) return;

    _refreshing = true;
    setState(() {});
    try {
      final results = await Future.wait(routers.map((router) async {
        final latency = await RouterStorageService.checkPing(router.host, router.port);
        return MapEntry(router.id, _PingStatus(latencyMs: latency));
      }));
      if (!mounted) return;

      final ids = routers.map((router) => router.id).toSet();
      setState(() {
        _pings.removeWhere((id, _) => !ids.contains(id));
        for (final result in results) {
          _pings[result.key] = result.value;
        }
      });
    } finally {
      _refreshing = false;
      if (mounted) setState(() {});
      if (_refreshQueued && mounted) {
        _refreshQueued = false;
        unawaited(_refreshPings());
      }
    }
  }

  Future<void> _editRouter({SavedRouter? router}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _panel,
      barrierColor: Colors.black.withOpacity(0.72),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => RouterEditorSheet(router: router),
    );
    if (!mounted || saved != true) return;
    await _refreshPings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(router == null ? 'تم حفظ الراوتر بنجاح' : 'تم تحديث بيانات الراوتر'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _deleteRouter(SavedRouter router) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('حذف الراوتر؟', textAlign: TextAlign.right),
        content: Text('سيتم حذف "${router.name}" وبيانات اتصاله من التخزين الآمن.', textAlign: TextAlign.right),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _red),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await ref.read(savedRoutersProvider.notifier).deleteRouter(router.id);
      if (!mounted) return;
      setState(() => _pings.remove(router.id));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تم حذف الراوتر'), behavior: SnackBarBehavior.floating),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر حذف الراوتر: ${_friendlyError(error)}'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _connectRouter(SavedRouter router) async {
    setState(() => _connectingId = router.id);
    try {
      try {
        await ref.read(activeRouterClientProvider.notifier).connectTo(router);
      } catch (error) {
        if (!router.useSsl || !mounted) rethrow;
        final accept = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: _panel,
            title: const Text('شهادة SSL غير موثوقة', textAlign: TextAlign.right),
            content: const Text(
              'تعذرت مصادقة شهادة الراوتر. هل تثق بهذه الشبكة وتريد قبول الشهادة المحلية لهذا الاتصال؟',
              textAlign: TextAlign.right,
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('قبول ومتابعة'),
              ),
            ],
          ),
        );
        if (accept != true || !mounted) rethrow;
        await ref.read(activeRouterClientProvider.notifier).connectTo(
          router,
          acceptInvalidCertificate: true,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم الاتصال بـ ${router.name}'), behavior: SnackBarBehavior.floating, backgroundColor: const Color(0xFF143C35)),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('فشل الاتصال: ${_friendlyError(error)}'), behavior: SnackBarBehavior.floating, backgroundColor: const Color(0xFF49212B)),
      );
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<List<SavedRouter>>>(savedRoutersProvider, (previous, next) {
      final before = previous?.valueOrNull?.map((r) => '${r.id}:${r.host}:${r.port}').join('|');
      final after = next.valueOrNull?.map((r) => '${r.id}:${r.host}:${r.port}').join('|');
      if (after != null && before != after) unawaited(_refreshPings());
    });

    final savedState = ref.watch(savedRoutersProvider);
    final activeRouter = ref.watch(activeRouterDetailsProvider);
    final routers = savedState.valueOrNull ?? const <SavedRouter>[];
    final online = routers.where((router) => _pings[router.id]?.latencyMs != null).length;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 20,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('الراوترات', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
            SizedBox(height: 3),
            Text('إدارة اتصالات MikroTik', style: TextStyle(fontSize: 11, color: _muted, fontWeight: FontWeight.w400)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'إعدادات التطبيق والأمان',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AppSettingsScreen())),
            icon: const Icon(Icons.security_rounded, color: _accent),
          ),
          IconButton(
            tooltip: 'إعادة فحص الاتصال',
            onPressed: _refreshing ? null : () => unawaited(_refreshPings()),
            icon: Icon(_refreshing ? Icons.sync : Icons.refresh_rounded, color: _accent),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editRouter(),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('إضافة راوتر', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
            child: _SummaryPanel(total: routers.length, online: online, refreshing: _refreshing),
          ),
          Expanded(
            child: savedState.when(
              loading: () => const Center(child: CircularProgressIndicator(color: _accent)),
              error: (error, stack) => _StateMessage(
                icon: Icons.lock_outline_rounded,
                title: 'تعذّر تحميل الراوترات',
                message: _friendlyError(error),
                actionLabel: 'إعادة المحاولة',
                onAction: () => ref.read(savedRoutersProvider.notifier).reload(),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return _StateMessage(
                    icon: Icons.router_outlined,
                    title: 'لا توجد راوترات محفوظة',
                    message: 'أضف راوتر MikroTik، ثم اختبر الاتصال وبيانات الدخول قبل حفظه.',
                    actionLabel: 'إضافة أول راوتر',
                    onAction: () => _editRouter(),
                  );
                }
                return RefreshIndicator(
                  color: _accent,
                  backgroundColor: _panel,
                  onRefresh: _refreshPings,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 104),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final router = list[index];
                      return _RouterCard(
                        router: router,
                        ping: _pings[router.id],
                        isActive: activeRouter?.id == router.id,
                        isConnecting: _connectingId == router.id,
                        onConnect: () => _connectRouter(router),
                        onEdit: () => _editRouter(router: router),
                        onDelete: () => _deleteRouter(router),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PingStatus {
  const _PingStatus({required this.latencyMs});
  final double? latencyMs;
}

class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({required this.total, required this.online, required this.refreshing});
  final int total;
  final int online;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final offline = (total - online).clamp(0, total);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xFF252344), Color(0xFF131A27), Color(0xFF111722)],
        ),
        border: Border.all(color: _accent.withOpacity(0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: _accent.withOpacity(0.16), borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.hub_rounded, color: _accent, size: 24),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('حالة الشبكة', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                    SizedBox(height: 4),
                    Text('فحص TCP لمنافذ إدارة الراوتر', style: TextStyle(color: _muted, fontSize: 11)),
                  ],
                ),
              ),
              if (refreshing)
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: _accent))
              else
                const Icon(Icons.radar_rounded, color: _accent, size: 23),
            ],
          ),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: _MetricBox(label: 'الراوترات', value: '$total', color: Colors.white)),
            const SizedBox(width: 10),
            Expanded(child: _MetricBox(label: 'متصلة بالـ TCP', value: '$online', color: _green)),
            const SizedBox(width: 10),
            Expanded(child: _MetricBox(label: 'غير متاحة', value: '$offline', color: _red)),
          ]),
        ],
      ),
    );
  }
}

class _MetricBox extends StatelessWidget {
  const _MetricBox({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.15),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withOpacity(0.045)),
        ),
        child: Column(children: [
          Text(value, style: TextStyle(fontSize: 23, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(height: 4),
          Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: _muted)),
        ]),
      );
}

class _RouterCard extends StatelessWidget {
  const _RouterCard({
    required this.router,
    required this.ping,
    required this.isActive,
    required this.isConnecting,
    required this.onConnect,
    required this.onEdit,
    required this.onDelete,
  });

  final SavedRouter router;
  final _PingStatus? ping;
  final bool isActive;
  final bool isConnecting;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final latency = ping?.latencyMs;
    final color = ping == null ? _muted : latency != null ? _green : _red;

    return Container(
      padding: const EdgeInsets.fromLTRB(15, 15, 11, 13),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isActive ? _accent.withOpacity(0.75) : Colors.white.withOpacity(0.065), width: isActive ? 1.3 : 1),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 18, offset: const Offset(0, 7))],
      ),
      child: Column(children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: (isActive ? _accent : const Color(0xFF283447)).withOpacity(0.18),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(Icons.router_rounded, color: isActive ? _accent : const Color(0xFFADB9CC), size: 26),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(router.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              Text('${router.host}:${router.port}', textDirection: TextDirection.ltr, style: const TextStyle(color: _muted, fontSize: 12)),
              const SizedBox(height: 9),
              Row(children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    boxShadow: ping == null ? const [] : [BoxShadow(color: color.withOpacity(0.55), blurRadius: 7)],
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    ping == null ? 'بانتظار الفحص' : latency != null ? 'Online  •  ${latency.toStringAsFixed(1)} ms' : 'Offline',
                    textDirection: latency != null ? TextDirection.ltr : TextDirection.rtl,
                    style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
                if (router.useSsl) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.lock_outline_rounded, size: 13, color: _muted),
                ],
                if (isActive) ...[
                  const SizedBox(width: 6),
                  const Text('جلسة نشطة', style: TextStyle(color: _accent, fontSize: 10, fontWeight: FontWeight.w700)),
                ],
              ]),
            ]),
          ),
          PopupMenuButton<String>(
            tooltip: 'خيارات الراوتر',
            color: const Color(0xFF1B2230),
            icon: const Icon(Icons.more_vert_rounded, color: _muted),
            onSelected: (value) {
              if (value == 'edit') onEdit();
              if (value == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit_outlined, size: 18), SizedBox(width: 10), Text('تعديل')])),
              PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline_rounded, size: 18, color: _red), SizedBox(width: 10), Text('حذف')])),
            ],
          ),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: Text(
              'API ${router.useSsl ? "SSL" : "TCP"}  ·  المستخدم: ${router.username}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _muted, fontSize: 10),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 38,
            child: FilledButton.icon(
              onPressed: isConnecting ? null : onConnect,
              style: FilledButton.styleFrom(
                backgroundColor: isActive ? const Color(0xFF1A443C) : _accent,
                disabledBackgroundColor: _accent.withOpacity(0.35),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              icon: isConnecting
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(isActive ? Icons.check_circle_outline_rounded : Icons.login_rounded, size: 16),
              label: Text(isConnecting ? 'جارٍ الاتصال' : isActive ? 'متصل' : 'اتصال', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ),
        ]),
      ]),
    );
  }
}

class RouterEditorSheet extends ConsumerStatefulWidget {
  const RouterEditorSheet({super.key, this.router});
  final SavedRouter? router;

  @override
  ConsumerState<RouterEditorSheet> createState() => _RouterEditorSheetState();
}

class _RouterEditorSheetState extends ConsumerState<RouterEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final String _id;

  bool _ssl = false;
  bool _allowBadCert = false;
  bool _testing = false;
  bool _saving = false;
  String? _testedFingerprint;
  String? _testSummary;
  String? _error;

  @override
  void initState() {
    super.initState();
    final router = widget.router;
    _id = router?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    _name = TextEditingController(text: router?.name ?? '');
    _host = TextEditingController(text: router?.host ?? '');
    _port = TextEditingController(text: '${router?.port ?? 8728}');
    _username = TextEditingController(text: router?.username ?? 'admin');
    _password = TextEditingController(text: router?.password ?? '');
    _ssl = router?.useSsl ?? false;
    for (final controller in [_name, _host, _port, _username, _password]) {
      controller.addListener(_invalidateTest);
    }
  }

  @override
  void dispose() {
    for (final controller in [_name, _host, _port, _username, _password]) {
      controller.removeListener(_invalidateTest);
      controller.dispose();
    }
    super.dispose();
  }

  void _invalidateTest() {
    if (_testedFingerprint != null || _testSummary != null || _error != null) {
      setState(() {
        _testedFingerprint = null;
        _testSummary = null;
        _error = null;
      });
    }
  }

  String _fingerprint() => [
        _name.text.trim(),
        _host.text.trim(),
        _port.text.trim(),
        _username.text.trim(),
        _password.text,
        _ssl.toString(),
        _allowBadCert.toString(),
      ].join(String.fromCharCode(31));

  SavedRouter _buildRouter() => SavedRouter(
        id: _id,
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _username.text.trim(),
        password: _password.text,
        useSsl: _ssl,
      );

  String? _required(String? value, String label) =>
      value == null || value.trim().isEmpty ? 'أدخل $label' : null;

  String? _validatePort(String? value) {
    final port = int.tryParse(value?.trim() ?? '');
    return port == null || port < 1 || port > 65535 ? 'أدخل منفذًا من 1 إلى 65535' : null;
  }

  Future<void> _testConnection() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _testing = true;
      _testedFingerprint = null;
      _testSummary = null;
      _error = null;
    });

    RouterOsClient? client;
    try {
      client = RouterOsClient(
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _username.text.trim(),
        password: _password.text,
        useSsl: _ssl,
        autoReconnect: false,
        onBadCertificate: _allowBadCert ? (certificate, host, port) => true : null,
      );
      await client.connect();
      final identityRows = await client.command('/system/identity/print');
      final resourceRows = await client.command('/system/resource/print');
      final identity = identityRows.isEmpty ? '' : (identityRows.first['name'] ?? '').trim();
      final version = resourceRows.isEmpty ? '' : (resourceRows.first['version'] ?? '').trim();

      if (identity.isEmpty) throw const RouterOsException('لم يُرجع الراوتر اسم الهوية.');
      if (version.isEmpty) throw const RouterOsException('تعذرت قراءة إصدار RouterOS.');
      if (_name.text.trim().isEmpty) _name.text = identity;

      if (!mounted) return;
      setState(() {
        _testedFingerprint = _fingerprint();
        _testSummary = '$identity  ·  RouterOS $version';
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _testedFingerprint = null;
        _testSummary = null;
        _error = _friendlyError(error);
      });
    } finally {
      if (client != null) await client.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _saveRouter() async {
    if (!_formKey.currentState!.validate()) return;
    if (_testedFingerprint == null || _testedFingerprint != _fingerprint()) {
      setState(() => _error = 'اختبر الاتصال أولًا. أي تغيير في البيانات يتطلب إعادة الاختبار.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(savedRoutersProvider.notifier).saveRouter(_buildRouter());
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = 'تعذر الحفظ: ${_friendlyError(error)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTested = _testedFingerprint != null && _testedFingerprint == _fingerprint();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(child: Container(width: 42, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(99)))),
                const SizedBox(height: 19),
                Row(children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: _accent.withOpacity(0.16), borderRadius: BorderRadius.circular(14)),
                    child: const Icon(Icons.router_rounded, color: _accent),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.router == null ? 'إضافة راوتر جديد' : 'تعديل بيانات الراوتر', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text('يجب نجاح اختبار RouterOS قبل الحفظ', style: TextStyle(color: _muted, fontSize: 11)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 20),
                _FieldLabel(label: 'اسم الراوتر', icon: Icons.badge_outlined, hint: 'يُجلب تلقائيًا إذا تركته فارغًا'),
                TextFormField(controller: _name, textDirection: TextDirection.rtl, textInputAction: TextInputAction.next, decoration: _inputDecoration('مثال: CCR2116 - المركز')),
                const SizedBox(height: 14),
                const _FieldLabel(label: 'عنوان IP أو DNS', icon: Icons.lan_outlined),
                TextFormField(
                  controller: _host,
                  textDirection: TextDirection.ltr,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                  validator: (value) => _required(value, 'عنوان الراوتر'),
                  decoration: _inputDecoration('192.168.88.1'),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                    flex: 5,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const _FieldLabel(label: 'منفذ API', icon: Icons.settings_ethernet_rounded),
                      TextFormField(
                        controller: _port,
                        textDirection: TextDirection.ltr,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        validator: _validatePort,
                        decoration: _inputDecoration(_ssl ? '8729' : '8728'),
                      ),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 6,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const _FieldLabel(label: 'الاتصال المشفّر', icon: Icons.lock_outline_rounded),
                      const SizedBox(height: 3),
                      Container(
                        height: 52,
                        decoration: BoxDecoration(color: const Color(0xFF0B1019), border: Border.all(color: Colors.white.withOpacity(0.08)), borderRadius: BorderRadius.circular(13)),
                        child: SwitchListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                          dense: true,
                          title: const Text('API-SSL', style: TextStyle(color: Colors.white, fontSize: 12)),
                          value: _ssl,
                          activeColor: _accent,
                          onChanged: (value) {
                            if (value && _port.text.trim() == '8728') _port.text = '8729';
                            if (!value && _port.text.trim() == '8729') _port.text = '8728';
                            setState(() {
                              _ssl = value;
                              _testedFingerprint = null;
                              _testSummary = null;
                              _error = null;
                            });
                          },
                        ),
                      ),
                    ]),
                  ),
                ]),
                const SizedBox(height: 14),
                const _FieldLabel(label: 'اسم المستخدم', icon: Icons.person_outline_rounded),
                TextFormField(
                  controller: _username,
                  textDirection: TextDirection.ltr,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  validator: (value) => _required(value, 'اسم المستخدم'),
                  decoration: _inputDecoration('admin'),
                ),
                const SizedBox(height: 14),
                const _FieldLabel(label: 'كلمة المرور', icon: Icons.password_rounded),
                TextFormField(
                  controller: _password,
                  textDirection: TextDirection.ltr,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  decoration: _inputDecoration('كلمة مرور الراوتر'),
                ),
                const SizedBox(height: 9),
                Container(
                  decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(13), border: Border.all(color: Colors.white.withOpacity(0.055))),
                  child: CheckboxListTile(
                    value: _allowBadCert,
                    onChanged: _testing || _saving ? null : (value) {
                      setState(() {
                        _allowBadCert = value ?? false;
                        _testedFingerprint = null;
                        _testSummary = null;
                        _error = null;
                      });
                    },
                    activeColor: _accent,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: const Text('قبول شهادة SSL محلية / غير موثوقة', style: TextStyle(color: Colors.white, fontSize: 12)),
                    subtitle: const Text('فعّلها فقط عند الوثوق بشبكة الإدارة والراوتر', style: TextStyle(color: _muted, fontSize: 10)),
                  ),
                ),
                const SizedBox(height: 16),
                if (_testSummary != null && isTested)
                  _FeedbackPanel(color: _green, icon: Icons.verified_rounded, text: 'نجح الاتصال: $_testSummary'),
                if (_error != null)
                  _FeedbackPanel(color: _red, icon: Icons.error_outline_rounded, text: _error!),
                if (_testSummary == null && _error == null)
                  const _FeedbackPanel(color: _muted, icon: Icons.info_outline_rounded, text: 'يقرأ الاختبار هوية الراوتر وإصدار RouterOS عبر API الفعلي.'),
                const SizedBox(height: 14),
                SizedBox(
                  height: 49,
                  child: OutlinedButton.icon(
                    onPressed: _testing || _saving ? null : _testConnection,
                    style: OutlinedButton.styleFrom(foregroundColor: _accent, side: BorderSide(color: _accent.withOpacity(0.65)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                    icon: _testing ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2, color: _accent)) : const Icon(Icons.network_check_rounded),
                    label: Text(_testing ? 'جارٍ اختبار الاتصال...' : 'فحص الاتصال (Test Connection)', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 49,
                  child: FilledButton.icon(
                    onPressed: _saving || _testing || !isTested ? null : _saveRouter,
                    style: FilledButton.styleFrom(
                      backgroundColor: _green,
                      disabledBackgroundColor: _green.withOpacity(0.22),
                      foregroundColor: const Color(0xFF07110F),
                      disabledForegroundColor: Colors.white38,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: _saving ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_outlined),
                    label: Text(_saving ? 'جارٍ الحفظ...' : widget.router == null ? 'حفظ الراوتر' : 'حفظ التعديلات', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label, required this.icon, this.hint});
  final String label;
  final IconData icon;
  final String? hint;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(children: [
          Icon(icon, size: 15, color: _accent),
          const SizedBox(width: 7),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          if (hint != null) ...[
            const SizedBox(width: 6),
            Expanded(child: Text(hint!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 9))),
          ],
        ]),
      );
}

class _FeedbackPanel extends StatelessWidget {
  const _FeedbackPanel({required this.color, required this.icon, required this.text});
  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(13), border: Border.all(color: color.withOpacity(0.28))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 9),
          Expanded(child: Text(text, style: TextStyle(color: color, height: 1.4, fontSize: 11, fontWeight: FontWeight.w600))),
        ]),
      );
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({required this.icon, required this.title, required this.message, required this.actionLabel, required this.onAction});
  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(width: 76, height: 76, decoration: BoxDecoration(color: _accent.withOpacity(0.12), shape: BoxShape.circle), child: Icon(icon, size: 36, color: _accent)),
            const SizedBox(height: 18),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 12, height: 1.6)),
            const SizedBox(height: 18),
            FilledButton.icon(onPressed: onAction, style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white), icon: const Icon(Icons.arrow_back_rounded, size: 17), label: Text(actionLabel)),
          ]),
        ),
      );
}

InputDecoration _inputDecoration(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF5D687B), fontSize: 12),
      filled: true,
      fillColor: const Color(0xFF0B1019),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      errorStyle: const TextStyle(fontSize: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: Colors.white.withOpacity(0.08))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: BorderSide(color: Colors.white.withOpacity(0.08))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: _accent, width: 1.2)),
      errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: _red)),
      focusedErrorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(13), borderSide: const BorderSide(color: _red, width: 1.2)),
    );

String _friendlyError(Object error) {
  if (error is TimeoutException) return 'انتهت مهلة الاتصال. تحقق من العنوان والمنفذ.';
  if (error is SocketException) return 'تعذر الوصول إلى المنفذ. تحقق من الشبكة وقواعد Firewall وخدمة API.';
  if (error is RouterOsException) return error.message;
  final message = error.toString();
  return message.startsWith('Exception: ') ? message.substring(11) : message;
}
