import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _ppBg = Color(0xFF080B12);
const Color _ppPanel = Color(0xFF111722);
const Color _ppMuted = Color(0xFF8D9AB0);
const Color _ppAccent = Color(0xFF8B7CFF);
const Color _ppGreen = Color(0xFF43D9A3);
const Color _ppRed = Color(0xFFFF657A);

class PppoeScreen extends ConsumerWidget {
  const PppoeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Center(child: Text('اتصل براوتر أولًا.'));
    return PppoeWorkspace(client: client);
  }
}

class PppoeWorkspace extends StatelessWidget {
  const PppoeWorkspace({super.key, required this.client});
  final RouterOsClient client;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Container(
              color: _ppBg,
              child: const TabBar(
                isScrollable: true,
                indicatorColor: _ppAccent,
                labelColor: Colors.white,
                unselectedLabelColor: _ppMuted,
                tabs: [
                  Tab(icon: Icon(Icons.people_alt_rounded, size: 18), text: 'PPPoE Secrets'),
                  Tab(icon: Icon(Icons.wifi_rounded, size: 18), text: 'PPPoE Active'),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _PppoeSecretsTab(client: client),
                  _PppoeActiveTab(client: client),
                ],
              ),
            ),
          ],
        ),
      );
}

class _PppoeSecret {
  const _PppoeSecret({
    required this.id,
    required this.name,
    required this.profile,
    required this.disabled,
    required this.service,
    required this.comment,
  });

  final String id;
  final String name;
  final String profile;
  final bool disabled;
  final String service;
  final String comment;

  factory _PppoeSecret.fromMap(Map<String, String> row) => _PppoeSecret(
        id: row['.id'] ?? '',
        name: row['name'] ?? '—',
        profile: row['profile'] ?? 'default',
        disabled: row['disabled'] == 'true',
        service: row['service'] ?? 'any',
        comment: row['comment'] ?? '',
      );
}

class _PppoeSecretsTab extends StatefulWidget {
  const _PppoeSecretsTab({required this.client});
  final RouterOsClient client;

  @override
  State<_PppoeSecretsTab> createState() => _PppoeSecretsTabState();
}

class _PppoeSecretsTabState extends State<_PppoeSecretsTab> {
  List<_PppoeSecret> _secrets = <_PppoeSecret>[];
  List<String> _profiles = <String>[];
  bool _loading = true;
  String? _error;
  final Set<String> _busy = <String>{};
  String _filter = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final result = await Future.wait<List<Map<String, String>>>([
        widget.client.command(
          '/ppp/secret/print',
          args: const <String, String>{'.proplist': '.id,name,profile,disabled,service,comment'},
        ),
        widget.client.command(
          '/ppp/profile/print',
          args: const <String, String>{'.proplist': 'name'},
        ),
      ]);
      final secrets = result[0]
          .map(_PppoeSecret.fromMap)
          .where((item) => item.name.isNotEmpty)
          .toList(growable: false)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final profiles = result[1]
          .map((row) => row['name'] ?? '')
          .where((name) => name.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      if (!mounted) return;
      setState(() {
        _secrets = secrets;
        _profiles = profiles;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = _friendly(error); });
    }
  }

  Future<void> _addSecret() async {
    final nameController = TextEditingController();
    final passwordController = TextEditingController();
    final noteController = TextEditingController();
    var selectedProfile = _profiles.contains('default') ? 'default' : (_profiles.isEmpty ? 'default' : _profiles.first);
    final formKey = GlobalKey<FormState>();
    final form = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: _ppPanel,
          title: const Text('إضافة مشترك PPPoE', style: TextStyle(color: Colors.white)),
          content: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameController,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'اسم المستخدم'),
                    validator: (value) => value == null || value.trim().isEmpty ? 'أدخل اسم المستخدم' : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'كلمة المرور'),
                    validator: (value) => value == null || value.isEmpty ? 'أدخل كلمة المرور' : null,
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _profiles.contains(selectedProfile) ? selectedProfile : null,
                    decoration: const InputDecoration(labelText: 'الباقة / Profile'),
                    items: _profiles.map((name) => DropdownMenuItem<String>(value: name, child: Text(name))).toList(),
                    onChanged: (value) {
                      if (value != null) setDialogState(() => selectedProfile = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(controller: noteController, decoration: const InputDecoration(labelText: 'ملاحظة اختيارية')),
                  if (_profiles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('لا توجد بروفايلات؛ سيُستخدم default.', style: TextStyle(color: _ppMuted, fontSize: 11)),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(dialogContext, <String, String>{
                    'name': nameController.text.trim(),
                    'password': passwordController.text,
                    'profile': _profiles.isEmpty ? 'default' : selectedProfile,
                    'comment': noteController.text.trim(),
                  });
                }
              },
              child: const Text('إضافة'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    passwordController.dispose();
    noteController.dispose();
    if (form == null || !mounted) return;
    try {
      await widget.client.command('/ppp/secret/add', args: <String, String>{
        'name': form['name']!,
        'password': form['password']!,
        'profile': form['profile']!,
        'service': 'pppoe',
        if ((form['comment'] ?? '').isNotEmpty) 'comment': form['comment']!,
      });
      _message('تمت إضافة المشترك ' + form['name']!);
      await _load();
    } catch (error) {
      _message('فشلت الإضافة: ' + _friendly(error), isError: true);
    }
  }

  Future<void> _changeProfile(_PppoeSecret secret) async {
    final options = _profiles.isEmpty ? <String>['default'] : _profiles;
    var selected = options.contains(secret.profile) ? secret.profile : options.first;
    final next = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: _ppPanel,
          title: Text('تغيير باقة ' + secret.name, style: const TextStyle(color: Colors.white)),
          content: DropdownButtonFormField<String>(
            value: selected,
            decoration: const InputDecoration(labelText: 'Profile'),
            items: options.map((name) => DropdownMenuItem<String>(value: name, child: Text(name))).toList(),
            onChanged: (value) { if (value != null) setDialogState(() => selected = value); },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, selected), child: const Text('حفظ الباقة')),
          ],
        ),
      ),
    );
    if (next == null || secret.id.isEmpty) return;
    await _run(secret.id, () => widget.client.command('/ppp/secret/set', args: <String, String>{'.id': secret.id, 'profile': next}), 'تم تغيير الباقة', reload: true);
  }

  Future<void> _toggleSecret(_PppoeSecret secret) async {
    if (secret.id.isEmpty) return;
    await _run(
      secret.id,
      () => widget.client.command('/ppp/secret/set', args: <String, String>{
        '.id': secret.id,
        'disabled': secret.disabled ? 'no' : 'yes',
      }),
      secret.disabled ? 'تم تفعيل الحساب' : 'تم تعطيل الحساب',
      reload: true,
    );
  }

  Future<void> _run(String id, Future<Object?> Function() action, String success, {bool reload = false}) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await action();
      if (!mounted) return;
      _message(success);
      if (reload) await _load();
    } catch (error) {
      if (mounted) _message(_friendly(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  void _message(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? _ppRed.withOpacity(0.95) : const Color(0xFF202839),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _secrets.where((secret) {
      final query = _filter.trim().toLowerCase();
      return query.isEmpty || secret.name.toLowerCase().contains(query) || secret.profile.toLowerCase().contains(query) || secret.comment.toLowerCase().contains(query);
    }).toList(growable: false);
    if (_loading && _secrets.isEmpty) return const Center(child: CircularProgressIndicator(color: _ppAccent));
    if (_error != null && _secrets.isEmpty) return _PppoeMessage(title: 'تعذر تحميل حسابات PPPoE', message: _error!, onRetry: _load);
    return RefreshIndicator(
      color: _ppAccent,
      backgroundColor: _ppPanel,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
        children: [
          _PppoeHeader(title: 'PPPoE Secrets', subtitle: 'قراءة وتعديل الحسابات من /ppp/secret', count: _secrets.length, onRefresh: _load),
          const SizedBox(height: 12),
          TextField(
            onChanged: (value) => setState(() => _filter = value),
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'بحث باسم المستخدم أو الباقة'),
          ),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            const _PppoeMessage(title: 'لا توجد حسابات مطابقة', message: 'اسحب للأسفل للتحديث أو أضف مشتركًا جديدًا.')
          else
            ...filtered.map((secret) => Container(
                  margin: const EdgeInsets.only(bottom: 9),
                  decoration: BoxDecoration(color: _ppPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: secret.disabled ? _ppRed.withOpacity(0.28) : Colors.white.withOpacity(0.06))),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 39,
                              height: 39,
                              decoration: BoxDecoration(color: (secret.disabled ? _ppRed : _ppGreen).withOpacity(0.13), borderRadius: BorderRadius.circular(12)),
                              child: Icon(secret.disabled ? Icons.person_off_rounded : Icons.person_rounded, color: secret.disabled ? _ppRed : _ppGreen),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(secret.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                                const SizedBox(height: 4),
                                Text('Profile: ' + secret.profile + '  ·  ' + secret.service, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _ppMuted, fontSize: 10)),
                              ]),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                              decoration: BoxDecoration(color: (secret.disabled ? _ppRed : _ppGreen).withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                              child: Text(secret.disabled ? 'معطّل' : 'فعّال', style: TextStyle(color: secret.disabled ? _ppRed : _ppGreen, fontSize: 10, fontWeight: FontWeight.w800)),
                            ),
                          ],
                        ),
                        if (secret.comment.isNotEmpty) ...[
                          const SizedBox(height: 7),
                          Align(alignment: Alignment.centerRight, child: Text(secret.comment, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _ppMuted, fontSize: 10))),
                        ],
                        const Divider(height: 20, color: Color(0xFF283142)),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _busy.contains(secret.id) ? null : () => _changeProfile(secret),
                                icon: const Icon(Icons.layers_rounded, size: 17),
                                label: const Text('تغيير الباقة'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.tonalIcon(
                                onPressed: _busy.contains(secret.id) ? null : () => _toggleSecret(secret),
                                icon: Icon(secret.disabled ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 17),
                                label: Text(secret.disabled ? 'تفعيل' : 'تعطيل'),
                                style: FilledButton.styleFrom(foregroundColor: secret.disabled ? _ppGreen : _ppRed),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )),
          const SizedBox(height: 75),
        ],
      ),
    );
  }
}

class _PppoeActiveSession {
  const _PppoeActiveSession({required this.id, required this.name, required this.address, required this.uptime, required this.service, required this.callerId});
  final String id;
  final String name;
  final String address;
  final String uptime;
  final String service;
  final String callerId;

  factory _PppoeActiveSession.fromMap(Map<String, String> row) => _PppoeActiveSession(
        id: row['.id'] ?? '',
        name: row['name'] ?? '—',
        address: row['address'] ?? '',
        uptime: row['uptime'] ?? '—',
        service: row['service'] ?? 'pppoe',
        callerId: row['caller-id'] ?? '',
      );
}

class _PppoeActiveTab extends StatefulWidget {
  const _PppoeActiveTab({required this.client});
  final RouterOsClient client;

  @override
  State<_PppoeActiveTab> createState() => _PppoeActiveTabState();
}

class _PppoeActiveTabState extends State<_PppoeActiveTab> {
  List<_PppoeActiveSession> _sessions = <_PppoeActiveSession>[];
  bool _loading = true;
  String? _error;
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command(
        '/ppp/active/print',
        args: const <String, String>{'.proplist': '.id,name,address,uptime,service,caller-id'},
      );
      final sessions = rows.map(_PppoeActiveSession.fromMap).toList(growable: false)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() { _sessions = sessions; _loading = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _error = _friendly(error); _loading = false; });
    }
  }

  Future<void> _disconnect(_PppoeActiveSession session) async {
    if (session.id.isEmpty || _busy.contains(session.id)) return;
    setState(() => _busy.add(session.id));
    try {
      await widget.client.command('/ppp/active/remove', args: <String, String>{'.id': session.id});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم فصل جلسة ' + session.name)));
      await _load();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشل الفصل: ' + _friendly(error)), backgroundColor: _ppRed));
    } finally {
      if (mounted) setState(() => _busy.remove(session.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _sessions.isEmpty) return const Center(child: CircularProgressIndicator(color: _ppAccent));
    if (_error != null && _sessions.isEmpty) return _PppoeMessage(title: 'تعذر تحميل الجلسات', message: _error!, onRetry: _load);
    return RefreshIndicator(
      color: _ppAccent,
      backgroundColor: _ppPanel,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
        children: [
          _PppoeHeader(title: 'PPPoE Active', subtitle: 'الجلسات المتصلة عبر /ppp/active', count: _sessions.length, onRefresh: _load),
          const SizedBox(height: 12),
          if (_sessions.isEmpty)
            const _PppoeMessage(title: 'لا توجد جلسات نشطة', message: 'سيظهر المشتركون المتصلون هنا مع عنوان IP ومدة الاتصال.')
          else
            ..._sessions.map((session) => Container(
                  margin: const EdgeInsets.only(bottom: 9),
                  decoration: BoxDecoration(color: _ppPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(0.06))),
                  child: Padding(
                    padding: const EdgeInsets.all(13),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Icon(Icons.wifi_tethering_rounded, color: _ppGreen, size: 22),
                        const SizedBox(width: 9),
                        Expanded(child: Text(session.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800))),
                        FilledButton.tonalIcon(
                          onPressed: _busy.contains(session.id) ? null : () => _disconnect(session),
                          icon: _busy.contains(session.id) ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link_off_rounded, size: 16),
                          label: const Text('فصل الجلسة'),
                          style: FilledButton.styleFrom(foregroundColor: _ppRed),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        _PppoePill(icon: Icons.language_rounded, label: 'IP: ' + (session.address.isEmpty ? '—' : session.address)),
                        _PppoePill(icon: Icons.timer_outlined, label: 'Uptime: ' + session.uptime),
                        if (session.callerId.isNotEmpty) _PppoePill(icon: Icons.router_rounded, label: session.callerId),
                        _PppoePill(icon: Icons.settings_ethernet_rounded, label: session.service),
                      ]),
                    ]),
                  ),
                )),
        ],
      ),
    );
  }
}

class _PppoeHeader extends StatelessWidget {
  const _PppoeHeader({required this.title, required this.subtitle, required this.count, required this.onRefresh});
  final String title;
  final String subtitle;
  final int count;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF292647), Color(0xFF111722)]),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _ppAccent.withOpacity(0.22)),
        ),
        child: Row(children: [
          const Icon(Icons.settings_ethernet_rounded, color: _ppAccent, size: 25),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            Text(subtitle, style: const TextStyle(color: _ppMuted, fontSize: 10)),
          ])),
          Text(count.toString(), style: const TextStyle(color: _ppGreen, fontSize: 22, fontWeight: FontWeight.w900)),
          IconButton(onPressed: onRefresh, tooltip: 'تحديث', icon: const Icon(Icons.refresh_rounded, color: _ppAccent)),
          IconButton(onPressed: null, tooltip: 'إضافة', icon: const Icon(Icons.person_add_alt_1_rounded, color: _ppAccent)),
        ]),
      );
}

class _PppoePill extends StatelessWidget {
  const _PppoePill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(10)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: _ppMuted),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: _ppMuted, fontSize: 10)),
        ]),
      );
}

class _PppoeMessage extends StatelessWidget {
  const _PppoeMessage({required this.title, required this.message, this.onRetry});
  final String title;
  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.router_rounded, color: _ppAccent, size: 37),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _ppMuted, fontSize: 12, height: 1.5)),
            if (onRetry != null) ...[
              const SizedBox(height: 14),
              OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh_rounded), label: const Text('إعادة المحاولة')),
            ],
          ]),
        ),
      );
}

String _friendly(Object error) {
  if (error is TimeoutException) return 'انتهت مهلة الاتصال بالراوتر.';
  if (error is RouterOsException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
