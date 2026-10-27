import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';
import 'hotspot_service.dart';
import 'voucher_pdf_service.dart';

const Color _hsBg = Color(0xFF080B12);
const Color _hsPanel = Color(0xFF111722);
const Color _hsMuted = Color(0xFF8D9AB0);
const Color _hsAccent = Color(0xFF8B7CFF);
const Color _hsGreen = Color(0xFF43D9A3);
const Color _hsRed = Color(0xFFFF657A);
const Color _hsBlue = Color(0xFF67B7FF);

class HotspotScreen extends ConsumerWidget {
  const HotspotScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const _HotspotNeedsRouter();
    return HotspotWorkspaceConnected(client: client);
  }
}

/// This wrapper deliberately receives the client through the RouterOS
/// connection scope exposed by the dashboard via [HotspotWorkspaceConnected].
class HotspotWorkspaceConnected extends StatelessWidget {
  const HotspotWorkspaceConnected({super.key, required this.client});
  final RouterOsClient client;

  @override
  Widget build(BuildContext context) {
    final service = HotspotService(client);
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          Container(
            color: _hsBg,
            child: const TabBar(
              isScrollable: true,
              dividerColor: Color(0xFF283142),
              indicatorColor: _hsAccent,
              labelColor: Colors.white,
              unselectedLabelColor: _hsMuted,
              tabs: [
                Tab(icon: Icon(Icons.people_alt_rounded, size: 18), text: 'Active'),
                Tab(icon: Icon(Icons.confirmation_number_rounded, size: 18), text: 'Generate'),
                Tab(icon: Icon(Icons.style_rounded, size: 18), text: 'Users'),
                Tab(icon: Icon(Icons.layers_rounded, size: 18), text: 'Profiles'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ActiveTab(service: service),
                _GenerateTab(service: service),
                _UsersTab(service: service),
                _ProfilesTab(service: service),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HotspotNeedsRouter extends StatelessWidget {
  const _HotspotNeedsRouter();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'لا توجد جلسة RouterOS نشطة. ارجع إلى قائمة الراوترات واتصل براوتر أولًا.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _hsMuted, height: 1.5),
          ),
        ),
      );
}

class ActiveHotspotPanel extends StatelessWidget {
  const ActiveHotspotPanel({super.key, required this.service});
  final HotspotService service;

  @override
  Widget build(BuildContext context) => _ActiveTab(service: service);
}

class _ActiveTab extends StatefulWidget {
  const _ActiveTab({required this.service});
  final HotspotService service;

  @override
  State<_ActiveTab> createState() => _ActiveTabState();
}

class _ActiveTabState extends State<_ActiveTab> {
  late Future<List<HotspotActiveSession>> _future;
  final Set<String> _kicking = <String>{};

  @override
  void initState() {
    super.initState();
    _future = widget.service.fetchActiveSessions();
  }

  void _reload() {
    setState(() => _future = widget.service.fetchActiveSessions());
  }

  Future<void> _kick(HotspotActiveSession session) async {
    if (session.id.isEmpty || _kicking.contains(session.id)) return;
    setState(() => _kicking.add(session.id));
    try {
      await widget.service.kickActiveSession(session.id);
      if (!mounted) return;
      _showSnack(context, 'تم طرد المستخدم ' + session.username);
      _reload();
    } catch (error) {
      if (mounted) _showSnack(context, 'فشل طرد المتصل: ' + _errorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _kicking.remove(session.id));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<HotspotActiveSession>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: _hsAccent));
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return _HotspotError(message: _errorText(snapshot.error!), onRetry: _reload);
          }
          final sessions = snapshot.data ?? const <HotspotActiveSession>[];
          return RefreshIndicator(
            color: _hsAccent,
            backgroundColor: _hsPanel,
            onRefresh: () async {
              final next = widget.service.fetchActiveSessions();
              setState(() => _future = next);
              await next;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 26),
              children: [
                _TabSummary(
                  title: 'المتصلون الآن',
                  subtitle: 'قراءة فعلية من /ip/hotspot/active/print',
                  value: sessions.length.toString(),
                  icon: Icons.wifi_tethering_rounded,
                  color: _hsGreen,
                  onRefresh: _reload,
                ),
                const SizedBox(height: 12),
                if (sessions.isEmpty)
                  const _EmptyPanel(
                    icon: Icons.people_outline_rounded,
                    title: 'لا يوجد متصلون حاليًا',
                    message: 'ستظهر الجلسات هنا فور تسجيل دخول عملاء الهوتسبوت.',
                  )
                else
                  ...sessions.map((session) => _ActiveSessionCard(
                        session: session,
                        busy: _kicking.contains(session.id),
                        onKick: () => _kick(session),
                      )),
              ],
            ),
          );
        },
      );
}

class _GenerateTab extends StatefulWidget {
  const _GenerateTab({required this.service});
  final HotspotService service;

  @override
  State<_GenerateTab> createState() => _GenerateTabState();
}

class _GenerateTabState extends State<_GenerateTab> {
  final _formKey = GlobalKey<FormState>();
  final _count = TextEditingController(text: '20');
  final _codeLength = TextEditingController(text: '6');
  final _prefix = TextEditingController(text: 'NOVA');
  final _limitGb = TextEditingController(text: '0');
  final _limitUptime = TextEditingController();
  final _networkName = TextEditingController(text: 'NOVA HOTSPOT');
  final _portalUrl = TextEditingController();
  final _price = TextEditingController();
  final _batchNote = TextEditingController();
  final VoucherPdfService _pdf = const VoucherPdfService();

  List<HotspotProfile> _profiles = <HotspotProfile>[];
  String? _selectedProfile;
  HotspotCredentialMode _credentialMode = HotspotCredentialMode.usernameOnly;
  bool _loadingProfiles = true;
  bool _working = false;
  String? _profileError;
  List<HotspotVoucher> _lastVouchers = <HotspotVoucher>[];

  @override
  void initState() {
    super.initState();
    unawaited(_loadProfiles());
  }

  @override
  void dispose() {
    for (final controller in [
      _count, _codeLength, _prefix, _limitGb, _limitUptime,
      _networkName, _portalUrl, _price, _batchNote,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    setState(() {
      _loadingProfiles = true;
      _profileError = null;
    });
    try {
      final profiles = await widget.service.fetchProfiles();
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        if (_selectedProfile == null || !profiles.any((profile) => profile.name == _selectedProfile)) {
          _selectedProfile = profiles.isEmpty ? null : profiles.first.name;
        }
        _loadingProfiles = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _profileError = _errorText(error);
        _loadingProfiles = false;
      });
    }
  }

  String? _positiveInteger(String? value, String label, {int minimum = 1, int maximum = 500}) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < minimum || parsed > maximum) {
      return label + ' يجب أن يكون بين ' + minimum.toString() + ' و' + maximum.toString();
    }
    return null;
  }

  Future<void> _generateAndExport() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    final selectedProfile = _profiles.where((profile) => profile.name == _selectedProfile).firstOrNull;
    if (selectedProfile == null) {
      _showSnack(context, 'أنشئ باقة من تبويب Profiles أولًا.', isError: true);
      return;
    }

    final gb = double.tryParse(_limitGb.text.trim()) ?? 0;
    if (gb < 0 || gb > 100000) {
      _showSnack(context, 'حد الجيجابايت يجب أن يكون بين 0 و100000.', isError: true);
      return;
    }
    final bytesLimit = gb <= 0 ? 0 : (gb * 1024 * 1024 * 1024).round();
    final batchId = DateTime.now().toUtc().millisecondsSinceEpoch.toString();

    setState(() => _working = true);
    try {
      final vouchers = await widget.service.generateVoucherBatch(
        VoucherBatchRequest(
          count: int.parse(_count.text.trim()),
          codeLength: int.parse(_codeLength.text.trim()),
          prefix: _prefix.text,
          profileName: selectedProfile.name,
          credentialMode: _credentialMode,
          batchId: batchId,
          limitBytesTotal: bytesLimit,
          limitUptime: _limitUptime.text.trim(),
          price: _price.text.trim(),
          validityLabel: selectedProfile.validityLabel,
          comment: _batchNote.text.trim(),
        ),
      );
      if (!mounted) return;
      setState(() => _lastVouchers = vouchers);
      try {
        await _pdf.shareVouchers(
          vouchers: vouchers,
          networkName: _networkName.text.trim(),
          portalUrl: _portalUrl.text.trim(),
        );
        if (mounted) _showSnack(context, 'تم إنشاء ' + vouchers.length.toString() + ' كرتًا وفتح مشاركة PDF.');
      } catch (error) {
        if (mounted) {
          _showSnack(
            context,
            'أُنشئت الكروت على الراوتر، لكن تعذر فتح PDF: ' + _errorText(error),
            isError: true,
          );
        }
      }
    } catch (error) {
      if (mounted) _showSnack(context, 'فشل التوليد: ' + _errorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _shareLastBatch() async {
    if (_lastVouchers.isEmpty) return;
    setState(() => _working = true);
    try {
      await _pdf.shareVouchers(
        vouchers: _lastVouchers,
        networkName: _networkName.text.trim(),
        portalUrl: _portalUrl.text.trim(),
      );
    } catch (error) {
      if (mounted) _showSnack(context, 'تعذر تصدير PDF: ' + _errorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _printLastBatch() async {
    if (_lastVouchers.isEmpty) return;
    setState(() => _working = true);
    try {
      await _pdf.printVouchers(
        vouchers: _lastVouchers,
        networkName: _networkName.text.trim(),
        portalUrl: _portalUrl.text.trim(),
      );
    } catch (error) {
      if (mounted) _showSnack(context, 'تعذرت الطباعة: ' + _errorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        const _TabSummary(
          title: 'مولّد الكروت',
          subtitle: 'إنشاء الحسابات على الراوتر ثم تصديرها إلى PDF',
          value: 'BATCH',
          icon: Icons.auto_awesome_rounded,
          color: _hsAccent,
        ),
        const SizedBox(height: 12),
        if (_loadingProfiles)
          const LinearProgressIndicator(color: _hsAccent)
        else if (_profileError != null)
          _Notice(color: _hsRed, icon: Icons.error_outline_rounded, text: _profileError!),
        if (!_loadingProfiles && _profiles.isEmpty)
          const _EmptyPanel(
            icon: Icons.layers_outlined,
            title: 'لا توجد باقات محفوظة',
            message: 'افتح تبويب Profiles وأنشئ باقة بصلاحية وسرعة قبل توليد الكروت.',
          ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: _hsPanel,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _FormHeading(title: 'إعدادات الدفعة', subtitle: 'حتى 500 كرت في العملية الواحدة'),
                const SizedBox(height: 13),
                Row(children: [
                  Expanded(
                    child: _InputField(
                      controller: _count,
                      label: 'عدد الكروت',
                      icon: Icons.numbers_rounded,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) => _positiveInteger(value, 'العدد', maximum: 500),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _InputField(
                      controller: _codeLength,
                      label: 'طول الكود',
                      icon: Icons.tag_rounded,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: (value) => _positiveInteger(value, 'طول الكود', minimum: 4, maximum: 24),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                _InputField(
                  controller: _prefix,
                  label: 'بادئة Prefix',
                  icon: Icons.short_text_rounded,
                  hint: 'NOVA',
                  validator: (value) => (value ?? '').length > 12 ? 'البادئة بحد أقصى 12 حرفًا' : null,
                ),
                const SizedBox(height: 12),
                const _FormFieldLabel(label: 'الباقة', icon: Icons.layers_rounded),
                DropdownButtonFormField<String>(
                  value: _profiles.any((profile) => profile.name == _selectedProfile) ? _selectedProfile : null,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF1B2230),
                  decoration: _decoration(hint: _loadingProfiles ? 'جارٍ تحميل الباقات' : 'اختر الباقة'),
                  items: _profiles.map((profile) => DropdownMenuItem<String>(
                    value: profile.name,
                    child: Text(
                      profile.name + ' · ' + profile.rateLimit + ' · ' + profile.validityLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  )).toList(growable: false),
                  onChanged: _loadingProfiles ? null : (value) => setState(() => _selectedProfile = value),
                ),
                const SizedBox(height: 12),
                const _FormFieldLabel(label: 'نوع الكرت', icon: Icons.vpn_key_rounded),
                DropdownButtonFormField<HotspotCredentialMode>(
                  value: _credentialMode,
                  isExpanded: true,
                  dropdownColor: const Color(0xFF1B2230),
                  decoration: _decoration(hint: 'طريقة الدخول'),
                  items: const [
                    DropdownMenuItem(
                      value: HotspotCredentialMode.usernameOnly,
                      child: Text('يوزر فقط', style: TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                    DropdownMenuItem(
                      value: HotspotCredentialMode.usernameAndPassword,
                      child: Text('يوزر وباسورد منفصلان', style: TextStyle(color: Colors.white, fontSize: 12)),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => _credentialMode = value);
                  },
                ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: _InputField(
                      controller: _limitGb,
                      label: 'حد الجيجابايت',
                      icon: Icons.data_usage_rounded,
                      hint: '0 = بلا حد',
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      validator: (value) {
                        final parsed = double.tryParse(value?.trim() ?? '');
                        return parsed == null || parsed < 0 || parsed > 100000
                            ? 'أدخل 0 إلى 100000'
                            : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _InputField(
                      controller: _limitUptime,
                      label: 'حد الاستخدام',
                      icon: Icons.timer_outlined,
                      hint: 'مثال: 2h',
                      validator: (value) {
                        final input = (value ?? '').trim();
                        if (input.isEmpty) return null;
                        return RegExp(r'^(?=.*\d)(?:\d+w)?(?:\d+d)?(?:\d+h)?(?:\d+m)?(?:\d+s)?$').hasMatch(input)
                            ? null
                            : 'مثال صالح: 1d أو 2h';
                      },
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                _InputField(controller: _price, label: 'السعر', icon: Icons.payments_outlined, hint: 'اختياري'),
                const SizedBox(height: 12),
                _InputField(controller: _batchNote, label: 'تعليق إضافي للدفعة', icon: Icons.notes_rounded, hint: 'اختياري'),
                const SizedBox(height: 12),
                const _FormHeading(title: 'بطاقات PDF', subtitle: 'اسم الشبكة ورابط صفحة الدخول المستخدم في QR'),
                const SizedBox(height: 10),
                _InputField(controller: _networkName, label: 'اسم الشبكة على البطاقة', icon: Icons.wifi_rounded, validator: (value) => (value ?? '').trim().isEmpty ? 'أدخل اسم الشبكة' : null),
                const SizedBox(height: 12),
                _InputField(
                  controller: _portalUrl,
                  label: 'رابط صفحة الدخول (اختياري)',
                  icon: Icons.qr_code_2_rounded,
                  hint: 'http://gateway/login',
                  keyboardType: TextInputType.url,
                  validator: (value) {
                    final input = (value ?? '').trim();
                    if (input.isEmpty) return null;
                    final uri = Uri.tryParse(input);
                    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty
                        ? null
                        : 'أدخل رابط HTTP أو HTTPS صالحًا';
                  },
                ),
                const SizedBox(height: 17),
                SizedBox(
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: _working || _profiles.isEmpty ? null : _generateAndExport,
                    style: FilledButton.styleFrom(
                      backgroundColor: _hsAccent,
                      disabledBackgroundColor: _hsAccent.withOpacity(0.3),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: _working
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.auto_awesome_rounded),
                    label: Text(_working ? 'جارٍ إنشاء الكروت وتجهيز PDF...' : 'توليد وتصدير PDF فورًا', style: const TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
                if (_lastVouchers.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _Notice(
                    color: _hsGreen,
                    icon: Icons.check_circle_outline_rounded,
                    text: 'آخر دفعة: ' + _lastVouchers.length.toString() + ' كرت. رقم الدفعة: ' + _lastVouchers.first.batchId,
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _working ? null : _shareLastBatch,
                        icon: const Icon(Icons.share_rounded, size: 18),
                        label: const Text('مشاركة PDF'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _working ? null : _printLastBatch,
                        icon: const Icon(Icons.print_rounded, size: 18),
                        label: const Text('طباعة'),
                      ),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _UsersTab extends StatefulWidget {
  const _UsersTab({required this.service});
  final HotspotService service;

  @override
  State<_UsersTab> createState() => _UsersTabState();
}

class _UsersTabState extends State<_UsersTab> {
  late Future<_UsersTabData> _future;
  final TextEditingController _query = TextEditingController();
  String? _profileFilter;
  bool _deletingExpired = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _query.addListener(_queryChanged);
  }

  @override
  void dispose() {
    _query.removeListener(_queryChanged);
    _query.dispose();
    super.dispose();
  }

  void _queryChanged() => setState(() {});

  Future<_UsersTabData> _load() async {
    final results = await Future.wait<Object>([
      widget.service.fetchUsers(),
      widget.service.fetchProfiles(),
    ]);
    return _UsersTabData(
      users: results[0] as List<HotspotUser>,
      profiles: results[1] as List<HotspotProfile>,
    );
  }

  void _reload() => setState(() => _future = _load());

  Future<void> _deleteExpired() async {
    setState(() => _deletingExpired = true);
    try {
      final count = await widget.service.deleteExpiredUsers();
      if (!mounted) return;
      _showSnack(context, count == 0 ? 'لا توجد كروت معلّمة كمنتهية.' : 'تم حذف ' + count.toString() + ' كرتًا منتهيًا.');
      _reload();
    } catch (error) {
      if (mounted) _showSnack(context, 'تعذر حذف الكروت المنتهية: ' + _errorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _deletingExpired = false);
    }
  }

  Future<void> _deleteOne(HotspotUser user) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _hsPanel,
        title: const Text('حذف الكرت؟'),
        content: Text('سيتم حذف المستخدم ' + user.username + ' نهائيًا من الراوتر.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _hsRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    try {
      await widget.service.deleteUser(user.id);
      if (mounted) {
        _showSnack(context, 'تم حذف ' + user.username);
        _reload();
      }
    } catch (error) {
      if (mounted) _showSnack(context, 'فشل الحذف: ' + _errorText(error), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_UsersTabData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: _hsAccent));
          }
          if (snapshot.hasError && !snapshot.hasData) {
            return _HotspotError(message: _errorText(snapshot.error!), onRetry: _reload);
          }
          final data = snapshot.data ?? const _UsersTabData(users: [], profiles: []);
          final query = _query.text.trim().toLowerCase();
          final users = data.users.where((user) {
            final profileOk = _profileFilter == null || _profileFilter!.isEmpty || user.profile == _profileFilter;
            final queryOk = query.isEmpty ||
                user.username.toLowerCase().contains(query) ||
                user.profile.toLowerCase().contains(query) ||
                user.comment.toLowerCase().contains(query);
            return profileOk && queryOk;
          }).toList(growable: false);

          return RefreshIndicator(
            color: _hsAccent,
            backgroundColor: _hsPanel,
            onRefresh: () async {
              final next = _load();
              setState(() => _future = next);
              await next;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
              children: [
                _TabSummary(
                  title: 'كروت الهوتسبوت',
                  subtitle: 'بحث بالاسم أو الباقة أو التعليق / رقم الدفعة',
                  value: users.length.toString(),
                  icon: Icons.style_rounded,
                  color: _hsBlue,
                  onRefresh: _reload,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(color: _hsPanel, borderRadius: BorderRadius.circular(17), border: Border.all(color: Colors.white.withOpacity(0.06))),
                  child: Column(children: [
                    TextField(
                      controller: _query,
                      decoration: _decoration(hint: 'فلترة بالباقة أو رقم الدفعة أو الاسم').copyWith(
                        prefixIcon: const Icon(Icons.search_rounded, color: _hsMuted),
                        suffixIcon: IconButton(
                          onPressed: () => _query.clear(),
                          icon: const Icon(Icons.close_rounded, color: _hsMuted),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: _profileFilter,
                      isExpanded: true,
                      dropdownColor: const Color(0xFF1B2230),
                      decoration: _decoration(hint: 'كل الباقات'),
                      items: [
                        const DropdownMenuItem<String>(value: null, child: Text('كل الباقات')),
                        ...data.profiles.map((profile) => DropdownMenuItem<String>(
                              value: profile.name,
                              child: Text(profile.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                            )),
                      ],
                      onChanged: (value) => setState(() => _profileFilter = value),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _deletingExpired ? null : _deleteExpired,
                        style: OutlinedButton.styleFrom(foregroundColor: _hsRed, side: BorderSide(color: _hsRed.withOpacity(0.45))),
                        icon: _deletingExpired
                            ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.delete_sweep_rounded, size: 18),
                        label: Text(_deletingExpired ? 'جارٍ حذف المنتهي...' : 'حذف الكروت المنتهية'),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                if (users.isEmpty)
                  const _EmptyPanel(
                    icon: Icons.search_off_rounded,
                    title: 'لا توجد كروت مطابقة',
                    message: 'غيّر كلمات البحث أو الباقة، أو أنشئ دفعة جديدة.',
                  )
                else
                  ...users.map((user) => _UserCard(user: user, onDelete: () => _deleteOne(user))),
              ],
            ),
          );
        },
      );
}

class _ProfilesTab extends StatefulWidget {
  const _ProfilesTab({required this.service});
  final HotspotService service;

  @override
  State<_ProfilesTab> createState() => _ProfilesTabState();
}

class _ProfilesTabState extends State<_ProfilesTab> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _rateLimit = TextEditingController(text: '2M/1M');
  final _days = TextEditingController(text: '1');
  final _hours = TextEditingController(text: '0');
  final _shared = TextEditingController(text: '1');
  late Future<List<HotspotProfile>> _future;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _future = widget.service.fetchProfiles();
  }

  @override
  void dispose() {
    _name.dispose();
    _rateLimit.dispose();
    _days.dispose();
    _hours.dispose();
    _shared.dispose();
    super.dispose();
  }

  void _reload() => setState(() => _future = widget.service.fetchProfiles());

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.service.createOrUpdateProfile(
        name: _name.text.trim(),
        rateLimit: _rateLimit.text.trim(),
        validityDays: int.parse(_days.text.trim()),
        validityHours: int.parse(_hours.text.trim()),
        sharedUsers: int.parse(_shared.text.trim()),
      );
      if (!mounted) return;
      _showSnack(context, 'تم إنشاء / تحديث الباقة مع سكريبت الصلاحية.');
      _name.clear();
      _reload();
    } catch (error) {
      if (mounted) _showSnack(context, 'تعذر حفظ الباقة: ' + _errorText(error), isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _boundedInteger(String? value, String label, int minimum, int maximum) {
    final parsed = int.tryParse(value?.trim() ?? '');
    return parsed == null || parsed < minimum || parsed > maximum
        ? label + ' يجب أن يكون بين ' + minimum.toString() + ' و' + maximum.toString()
        : null;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<HotspotProfile>>(
        future: _future,
        builder: (context, snapshot) {
          final profiles = snapshot.data ?? const <HotspotProfile>[];
          return RefreshIndicator(
            color: _hsAccent,
            backgroundColor: _hsPanel,
            onRefresh: () async {
              final next = widget.service.fetchProfiles();
              setState(() => _future = next);
              await next;
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
              children: [
                _TabSummary(
                  title: 'باقات الهوتسبوت',
                  subtitle: 'تحديد السرعة والصلاحية التي تبدأ من أول دخول',
                  value: profiles.length.toString(),
                  icon: Icons.layers_rounded,
                  color: _hsAccent,
                  onRefresh: _reload,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(15),
                  decoration: BoxDecoration(color: _hsPanel, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(0.06))),
                  child: Form(
                    key: _formKey,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const _FormHeading(title: 'إضافة أو تحديث باقة', subtitle: 'تُحقن آلية انتهاء الصلاحية في on-login'),
                      const SizedBox(height: 12),
                      _InputField(
                        controller: _name,
                        label: 'اسم الباقة',
                        icon: Icons.sell_outlined,
                        validator: (value) => (value ?? '').trim().isEmpty ? 'أدخل اسم الباقة' : null,
                      ),
                      const SizedBox(height: 12),
                      _InputField(
                        controller: _rateLimit,
                        label: 'سرعة التحميل / الرفع',
                        icon: Icons.speed_rounded,
                        hint: 'مثال: 10M/2M',
                        validator: (value) {
                          final text = (value ?? '').trim();
                          if (text.isEmpty) return 'أدخل سرعة مثل 10M/2M';
                          return RegExp(r'^[0-9]+[kKmMgG]?(\/[0-9]+[kKmMgG]?)?$').hasMatch(text)
                              ? null
                              : 'صيغة السرعة غير صحيحة';
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                          child: _InputField(
                            controller: _days,
                            label: 'الصلاحية بالأيام',
                            icon: Icons.calendar_month_rounded,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            validator: (value) => _boundedInteger(value, 'الأيام', 0, 3650),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _InputField(
                            controller: _hours,
                            label: 'الساعات الإضافية',
                            icon: Icons.schedule_rounded,
                            keyboardType: TextInputType.number,
                            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                            validator: (value) => _boundedInteger(value, 'الساعات', 0, 23),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      _InputField(
                        controller: _shared,
                        label: 'عدد المستخدمين المشتركين',
                        icon: Icons.people_outline_rounded,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        validator: (value) => _boundedInteger(value, 'عدد المستخدمين', 1, 1000),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 47,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _saveProfile,
                          style: FilledButton.styleFrom(backgroundColor: _hsAccent, foregroundColor: Colors.white),
                          icon: _saving
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.save_outlined),
                          label: Text(_saving ? 'جارٍ حفظ الباقة...' : 'حفظ الباقة'),
                        ),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 13),
                if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData)
                  const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: _hsAccent)))
                else if (snapshot.hasError && !snapshot.hasData)
                  _HotspotError(message: _errorText(snapshot.error!), onRetry: _reload)
                else if (profiles.isEmpty)
                  const _EmptyPanel(
                    icon: Icons.layers_outlined,
                    title: 'لا توجد باقات',
                    message: 'أضف باقة لتظهر خياراتها عند توليد الكروت.',
                  )
                else
                  ...profiles.map((profile) => _ProfileCard(profile: profile)),
              ],
            ),
          );
        },
      );
}

class _UsersTabData {
  const _UsersTabData({required this.users, required this.profiles});
  final List<HotspotUser> users;
  final List<HotspotProfile> profiles;
}

class _TabSummary extends StatelessWidget {
  const _TabSummary({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.icon,
    required this.color,
    this.onRefresh,
  });

  final String title;
  final String subtitle;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [Color(0xFF292647), Color(0xFF111722)]),
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: color.withOpacity(0.2)),
        ),
        child: Row(children: [
          Container(width: 43, height: 43, decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: color, size: 23)),
          const SizedBox(width: 11),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: _hsMuted, fontSize: 10, height: 1.35)),
          ])),
          const SizedBox(width: 7),
          Text(value, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w900)),
          if (onRefresh != null)
            IconButton(onPressed: onRefresh, icon: const Icon(Icons.refresh_rounded, color: _hsMuted), tooltip: 'تحديث'),
        ]),
      );
}

class _ActiveSessionCard extends StatelessWidget {
  const _ActiveSessionCard({required this.session, required this.busy, required this.onKick});
  final HotspotActiveSession session;
  final bool busy;
  final VoidCallback onKick;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: _hsPanel, borderRadius: BorderRadius.circular(17), border: Border.all(color: Colors.white.withOpacity(0.055))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(width: 39, height: 39, decoration: BoxDecoration(color: _hsGreen.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.person_rounded, color: _hsGreen)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(session.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(session.address.isEmpty ? 'IP غير متوفر' : session.address, textDirection: TextDirection.ltr, style: const TextStyle(color: _hsMuted, fontSize: 11)),
            ])),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(color: _hsGreen.withOpacity(0.12), borderRadius: BorderRadius.circular(8)), child: const Text('ONLINE', style: TextStyle(color: _hsGreen, fontSize: 9, fontWeight: FontWeight.w900))),
          ]),
          const SizedBox(height: 13),
          Wrap(spacing: 8, runSpacing: 8, children: [
            _InfoPill(label: 'Uptime', value: session.uptime, color: _hsBlue),
            _InfoPill(label: 'RX', value: _formatBytes(session.bytesIn), color: _hsGreen),
            _InfoPill(label: 'TX', value: _formatBytes(session.bytesOut), color: _hsBlue),
            if (session.profile.isNotEmpty) _InfoPill(label: 'Profile', value: session.profile, color: _hsAccent),
          ]),
          if (session.macAddress.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('MAC: ' + session.macAddress, textDirection: TextDirection.ltr, style: const TextStyle(color: _hsMuted, fontSize: 10)),
          ],
          const SizedBox(height: 11),
          SizedBox(
            height: 38,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onKick,
              style: OutlinedButton.styleFrom(foregroundColor: _hsRed, side: BorderSide(color: _hsRed.withOpacity(0.4))),
              icon: busy ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link_off_rounded, size: 17),
              label: Text(busy ? 'جارٍ الطرد...' : 'طرد المتصل (Kick)'),
            ),
          ),
        ]),
      );
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user, required this.onDelete});
  final HotspotUser user;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(color: _hsPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(0.055))),
        child: Row(children: [
          Container(width: 38, height: 38, decoration: BoxDecoration(color: user.isExpired ? _hsRed.withOpacity(0.12) : _hsBlue.withOpacity(0.12), borderRadius: BorderRadius.circular(11)), child: Icon(user.isExpired ? Icons.timer_off_rounded : Icons.confirmation_number_rounded, color: user.isExpired ? _hsRed : _hsBlue, size: 19)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(user.username, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(user.profile + (user.disabled ? ' · Disabled' : ''), style: TextStyle(color: user.disabled ? _hsRed : _hsMuted, fontSize: 10)),
            if (user.comment.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(user.comment, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _hsMuted, fontSize: 9)),
            ],
            if (user.limitUptime.isNotEmpty || user.limitBytesTotal > 0) ...[
              const SizedBox(height: 4),
              Text(
                (user.limitUptime.isEmpty ? '' : 'Time: ' + user.limitUptime) +
                    (user.limitBytesTotal == 0 ? '' : '  ·  Data: ' + _formatBytes(user.limitBytesTotal)),
                style: const TextStyle(color: _hsBlue, fontSize: 9),
              ),
            ],
          ])),
          IconButton(tooltip: 'حذف الكرت', onPressed: onDelete, icon: const Icon(Icons.delete_outline_rounded, color: _hsRed)),
        ]),
      );
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile});
  final HotspotProfile profile;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 9),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: _hsPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(0.055))),
        child: Row(children: [
          Container(width: 39, height: 39, decoration: BoxDecoration(color: _hsAccent.withOpacity(0.13), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.layers_rounded, color: _hsAccent)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(profile.name, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
            const SizedBox(height: 5),
            Text('Rate limit: ' + (profile.rateLimit.isEmpty ? 'غير محدد' : profile.rateLimit), style: const TextStyle(color: _hsBlue, fontSize: 10)),
            const SizedBox(height: 3),
            Text('Validity: ' + profile.validityLabel, style: const TextStyle(color: _hsGreen, fontSize: 10)),
            if (profile.comment.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(profile.comment, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _hsMuted, fontSize: 9)),
            ],
          ])),
        ]),
      );
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(color: color.withOpacity(0.09), borderRadius: BorderRadius.circular(9)),
        child: Text(label + ': ' + value, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
      );
}

class _FormHeading extends StatelessWidget {
  const _FormHeading({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(color: _hsMuted, fontSize: 10)),
      ]);
}

class _InputField extends StatelessWidget {
  const _InputField({
    required this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.keyboardType,
    this.inputFormatters,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hint;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _FormFieldLabel(label: label, icon: icon),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          validator: validator,
          autocorrect: false,
          decoration: _decoration(hint: hint ?? label),
        ),
      ]);
}

class _FormFieldLabel extends StatelessWidget {
  const _FormFieldLabel({required this.label, required this.icon});
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(children: [
          Icon(icon, size: 15, color: _hsAccent),
          const SizedBox(width: 7),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 28),
        decoration: BoxDecoration(color: _hsPanel, borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.white.withOpacity(0.055))),
        child: Column(children: [
          Icon(icon, color: _hsAccent, size: 37),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 7),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _hsMuted, fontSize: 11, height: 1.5)),
        ]),
      );
}

class _HotspotError extends StatelessWidget {
  const _HotspotError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(26),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off_rounded, color: _hsRed, size: 38),
            const SizedBox(height: 12),
            const Text('تعذر تحميل بيانات الهوتسبوت', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _hsMuted, fontSize: 11, height: 1.4)),
            const SizedBox(height: 12),
            FilledButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('إعادة المحاولة')),
          ]),
        ),
      );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.color, required this.icon, required this.text});
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

InputDecoration _decoration({required String hint}) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF5D687B), fontSize: 11),
      filled: true,
      fillColor: const Color(0xFF0B1019),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      errorStyle: const TextStyle(fontSize: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF283142))),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF283142))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _hsAccent, width: 1.2)),
    );

String _formatBytes(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  return value.toStringAsFixed(index == 0 ? 0 : 1) + ' ' + units[index];
}

String _errorText(Object error) {
  if (error is TimeoutException) return 'انتهت مهلة الاتصال بالراوتر.';
  if (error is SocketException) return 'تعذر الوصول إلى خدمة API في الراوتر.';
  if (error is RouterOsException) return error.message;
  final text = error.toString();
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}

void _showSnack(BuildContext context, String message, {bool isError = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: isError ? const Color(0xFF49212B) : const Color(0xFF202839),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
