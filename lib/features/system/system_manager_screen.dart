import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const _smPanel = Color(0xFF111722);
const _smMuted = Color(0xFF8D9AB0);
const _smAccent = Color(0xFF8B7CFF);
const _smGreen = Color(0xFF43D9A3);
const _smRed = Color(0xFFFF657A);
const _smAmber = Color(0xFFFFB45E);

class SystemManagerScreen extends ConsumerWidget {
  const SystemManagerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Center(child: Text('اتصل براوتر أولًا.'));
    return SystemManagerWorkspace(client: client);
  }
}

class SystemManagerWorkspace extends StatelessWidget {
  const SystemManagerWorkspace({super.key, required this.client});
  final RouterOsClient client;

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 3,
        child: Column(children: [
          Container(
            color: const Color(0xFF080B12),
            child: const TabBar(
              isScrollable: true,
              indicatorColor: _smAccent,
              labelColor: Colors.white,
              unselectedLabelColor: _smMuted,
              tabs: [
                Tab(icon: Icon(Icons.code_rounded, size: 18), text: 'Scripts'),
                Tab(icon: Icon(Icons.schedule_rounded, size: 18), text: 'Scheduler'),
                Tab(icon: Icon(Icons.build_circle_outlined, size: 18), text: 'Maintenance'),
              ],
            ),
          ),
          Expanded(child: TabBarView(children: [
            _ScriptsTab(client: client),
            _SchedulerTab(client: client),
            _MaintenanceTab(client: client),
          ])),
        ]),
      );
}

class _ScriptsTab extends StatefulWidget {
  const _ScriptsTab({required this.client});
  final RouterOsClient client;
  @override
  State<_ScriptsTab> createState() => _ScriptsTabState();
}

class _ScriptsTabState extends State<_ScriptsTab> {
  List<Map<String, String>> _scripts = [];
  bool _loading = true, _reading = false;
  String? _error;
  final Set<String> _running = {};

  @override
  void initState() { super.initState(); unawaited(_load()); }

  Future<void> _load() async {
    if (_reading) return;
    _reading = true;
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command('/system/script/print', args: const {
        '.proplist': '.id,name,owner,policy,run-count,last-started,comment,disabled',
      });
      if (mounted) setState(() { _scripts = rows; _loading = false; _error = null; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = _smFriendly(e); });
    } finally { _reading = false; }
  }

  Future<void> _run(Map<String, String> script) async {
    final id = script['.id'] ?? '';
    final name = script['name'] ?? '';
    if (id.isEmpty || name.isEmpty || _running.contains(id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تشغيل Script؟'),
        content: Text('سيتم تنفيذ السكريبت "' + name + '" مباشرة على الراوتر. تأكد من محتواه قبل المتابعة.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Run Script')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _running.add(id));
    try {
      await widget.client.command('/system/script/run', args: <String, String>{'number': id});
      if (mounted) _smMessage(context, 'أُرسل أمر تشغيل السكريبت: ' + name);
      await _load();
    } catch (e) {
      if (mounted) _smMessage(context, 'تعذر تشغيل السكريبت: ' + _smFriendly(e), isError: true);
    } finally { if (mounted) setState(() => _running.remove(id)); }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _scripts.isEmpty) return const Center(child: CircularProgressIndicator(color: _smAccent));
    if (_error != null && _scripts.isEmpty) return _SmRetry(title: 'تعذر قراءة السكريبتات', error: _error!, retry: () => _load());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(13), children: [
        _SmHeader(title: 'System Scripts', subtitle: '/system/script/print', count: _scripts.length, refresh: () => _load()),
        const SizedBox(height: 8),
        const Text('Run-count يعكس عدد مرات التشغيل المتزامنة التي يبلغ عنها RouterOS، وليس سجلًا تراكميًا مضمونًا.', style: TextStyle(color: _smMuted, fontSize: 10)),
        if (_error != null) Text(_error!, style: const TextStyle(color: _smRed)),
        if (_scripts.isEmpty) const _SmEmpty(text: 'لا توجد سكريبتات مخزنة على الراوتر.'),
        ..._scripts.map((script) {
          final id = script['.id'] ?? '';
          final name = script['name'] ?? '(بدون اسم)';
          final disabled = script['disabled'] == 'true';
          final busy = _running.contains(id);
          return Card(
            color: _smPanel,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.terminal_rounded, color: disabled ? _smMuted : _smAccent),
                  const SizedBox(width: 8),
                  Expanded(child: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))),
                  Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(color: (disabled ? _smMuted : _smGreen).withOpacity(0.12), borderRadius: BorderRadius.circular(8)), child: Text(disabled ? 'DISABLED' : 'ENABLED', style: TextStyle(color: disabled ? _smMuted : _smGreen, fontSize: 9, fontWeight: FontWeight.bold))),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  _SmPill(label: 'Run-count: ' + (script['run-count'] ?? '0')),
                  if ((script['owner'] ?? '').isNotEmpty) _SmPill(label: 'Owner: ' + script['owner']!),
                  if ((script['policy'] ?? '').isNotEmpty) _SmPill(label: 'Policy: ' + script['policy']!),
                ]),
                if ((script['comment'] ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 7), child: Text(script['comment']!, style: const TextStyle(color: _smMuted, fontSize: 10))),
                if ((script['last-started'] ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 5), child: Text('Last started: ' + script['last-started']!, style: const TextStyle(color: _smMuted, fontSize: 10))),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: FilledButton.icon(
                  onPressed: disabled || busy ? null : () => _run(script),
                  icon: busy ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_arrow_rounded),
                  label: const Text('Run Script'),
                )),
              ]),
            ),
          );
        }),
      ]),
    );
  }
}

class _SchedulerTab extends StatefulWidget {
  const _SchedulerTab({required this.client});
  final RouterOsClient client;
  @override
  State<_SchedulerTab> createState() => _SchedulerTabState();
}

class _SchedulerTabState extends State<_SchedulerTab> {
  List<Map<String, String>> _tasks = [];
  bool _loading = true, _reading = false;
  String? _error;
  final Set<String> _busy = {};

  @override
  void initState() { super.initState(); unawaited(_load()); }

  Future<void> _load() async {
    if (_reading) return;
    _reading = true;
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command('/system/scheduler/print', args: const {
        '.proplist': '.id,name,start-date,start-time,interval,next-run,on-event,disabled,run-count,comment',
      });
      if (mounted) setState(() { _tasks = rows; _loading = false; _error = null; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = _smFriendly(e); });
    } finally { _reading = false; }
  }

  Future<void> _toggle(Map<String, String> task) async {
    final id = task['.id'] ?? '';
    if (id.isEmpty || _busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      final disabled = task['disabled'] == 'true';
      await widget.client.command('/system/scheduler/set', args: <String, String>{'.id': id, 'disabled': disabled ? 'no' : 'yes'});
      if (mounted) _smMessage(context, disabled ? 'تم تفعيل المهمة.' : 'تم تعطيل المهمة.');
      await _load();
    } catch (e) {
      if (mounted) _smMessage(context, 'تعذر تعديل المهمة: ' + _smFriendly(e), isError: true);
    } finally { if (mounted) setState(() => _busy.remove(id)); }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _tasks.isEmpty) return const Center(child: CircularProgressIndicator(color: _smAccent));
    if (_error != null && _tasks.isEmpty) return _SmRetry(title: 'تعذر قراءة Scheduler', error: _error!, retry: _load);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(13), children: [
        _SmHeader(title: 'System Scheduler', subtitle: '/system/scheduler/print', count: _tasks.length, refresh: _load),
        if (_error != null) Text(_error!, style: const TextStyle(color: _smRed)),
        if (_tasks.isEmpty) const _SmEmpty(text: 'لا توجد مهام مجدولة.'),
        ..._tasks.map((task) {
          final id = task['.id'] ?? '';
          final disabled = task['disabled'] == 'true';
          final name = task['name'] ?? '(بدون اسم)';
          return Card(color: _smPanel, child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.schedule_rounded, color: disabled ? _smMuted : _smGreen),
              const SizedBox(width: 8),
              Expanded(child: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900))),
              Switch(value: !disabled, activeColor: _smGreen, onChanged: _busy.contains(id) ? null : (_) => _toggle(task)),
            ]),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _SmPill(label: 'Next run: ' + ((task['next-run'] ?? '').isEmpty ? '—' : task['next-run']!)),
              if ((task['interval'] ?? '').isNotEmpty) _SmPill(label: 'Interval: ' + task['interval']!),
              if ((task['start-time'] ?? '').isNotEmpty) _SmPill(label: 'Start: ' + task['start-time']!),
              _SmPill(label: disabled ? 'Disabled' : 'Enabled', color: disabled ? _smMuted : _smGreen),
            ]),
            if ((task['comment'] ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(task['comment']!, style: const TextStyle(color: _smMuted, fontSize: 10))),
            if ((task['on-event'] ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 7), child: Text(task['on-event']!, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _smMuted, fontSize: 10))),
          ])));
        }),
      ]),
    );
  }
}

class _MaintenanceTab extends StatefulWidget {
  const _MaintenanceTab({required this.client});
  final RouterOsClient client;
  @override
  State<_MaintenanceTab> createState() => _MaintenanceTabState();
}

class _MaintenanceTabState extends State<_MaintenanceTab> {
  List<Map<String, String>> _files = [];
  bool _loading = true, _reading = false, _actionBusy = false;
  String? _error;
  final _fileName = TextEditingController(text: 'nova-export');

  @override
  void initState() { super.initState(); unawaited(_loadFiles()); }
  @override
  void dispose() { _fileName.dispose(); super.dispose(); }

  Future<void> _loadFiles() async {
    if (_reading) return;
    _reading = true;
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command('/file/print', args: const {
        '.proplist': '.id,name,type,size,creation-time,modification-time',
      });
      if (mounted) setState(() { _files = rows; _loading = false; _error = null; });
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = _smFriendly(e); });
    } finally { _reading = false; }
  }

  Future<void> _action(String label, Future<void> Function() action) async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      await action();
      if (mounted) _smMessage(context, label);
      await _loadFiles();
    } catch (e) {
      if (mounted) _smMessage(context, 'فشلت العملية: ' + _smFriendly(e), isError: true);
    } finally { if (mounted) setState(() => _actionBusy = false); }
  }

  Future<void> _backup() async {
    await _action('أُرسل أمر إنشاء النسخة الاحتياطية. تحقق من ظهور ملف .backup في القائمة.', () async {
      await widget.client.command('/system/backup/save', args: const {'name': 'nova-backup'});
    });
  }

  Future<void> _export() async {
    final name = _fileName.text.trim();
    if (name.isEmpty || !RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(name)) {
      _smMessage(context, 'اسم الملف يسمح بالحروف الإنجليزية والأرقام والشرطة فقط.', isError: true);
      return;
    }
    await _action('أُرسل أمر تصدير الإعدادات إلى ' + name + '.rsc', () async {
      await widget.client.command('/export', args: <String, String>{'file': name});
    });
  }

  Future<bool> _confirm(String title, String body, String confirmLabel) async {
    return await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirmLabel)),
      ],
    )) ?? false;
  }

  Future<void> _powerAction({required bool reboot}) async {
    final first = await _confirm(
      reboot ? 'إعادة تشغيل الراوتر؟' : 'إيقاف تشغيل الراوتر؟',
      reboot
          ? 'سينقطع اتصال الإدارة والعملاء حتى يعود الراوتر. تأكد من توفر وصول بديل.'
          : 'قد يتوقف الراوتر والشبكة بالكامل. استخدم هذا فقط على جهاز يدعم الإيقاف الآمن.',
      reboot ? 'متابعة' : 'متابعة',
    );
    if (!first || !mounted) return;
    final second = await _confirm(
      'تأكيد نهائي',
      reboot ? 'هل تؤكد إرسال أمر /system/reboot الآن؟' : 'هل تؤكد إرسال أمر /system/shutdown الآن؟',
      reboot ? 'إعادة التشغيل الآن' : 'إيقاف التشغيل الآن',
    );
    if (!second) return;
    await _action(reboot ? 'تم إرسال أمر إعادة التشغيل.' : 'تم إرسال أمر إيقاف التشغيل.', () async {
      await widget.client.command(reboot ? '/system/reboot' : '/system/shutdown');
    });
  }

  String _fileSize(String value) {
    final bytes = int.tryParse(value);
    if (bytes == null) return value.isEmpty ? '—' : value;
    if (bytes >= 1024 * 1024) return (bytes / (1024 * 1024)).toStringAsFixed(1) + ' MB';
    if (bytes >= 1024) return (bytes / 1024).toStringAsFixed(1) + ' KB';
    return bytes.toString() + ' B';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _files.isEmpty) return const Center(child: CircularProgressIndicator(color: _smAccent));
    return RefreshIndicator(
      onRefresh: _loadFiles,
      child: ListView(padding: const EdgeInsets.all(13), children: [
        _SmHeader(title: 'Maintenance & Backup', subtitle: 'عمليات مباشرة على الراوتر', count: _files.length, refresh: _loadFiles),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(color: _smPanel, borderRadius: BorderRadius.circular(15)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('النسخ والتصدير', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900)),
            const SizedBox(height: 7),
            const Text('تُحفظ الملفات داخل الراوتر؛ هذه الأوامر لا تنزّلها تلقائيًا إلى الهاتف.', style: TextStyle(color: _smMuted, fontSize: 10)),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              onPressed: _actionBusy ? null : _backup,
              icon: const Icon(Icons.save_alt_rounded),
              label: const Text('إنشاء نسخة احتياطية (.backup)'),
            )),
            TextField(controller: _fileName, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'اسم ملف التصدير', suffixText: '.rsc')),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(
              onPressed: _actionBusy ? null : _export,
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('تصدير الإعدادات (/export)'),
            )),
            if (_actionBusy) const LinearProgressIndicator(),
          ]),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(color: _smPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: _smRed.withOpacity(0.2))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('عمليات الطاقة — حذرة', style: TextStyle(color: _smRed, fontSize: 13, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            const Text('كل إجراء يتطلب تأكيدين منفصلين. قد يؤدي الإيقاف إلى فقدان الوصول للشبكة.', style: TextStyle(color: _smMuted, fontSize: 10)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: _actionBusy ? null : () => _powerAction(reboot: true), icon: const Icon(Icons.restart_alt_rounded), label: const Text('إعادة تشغيل'), style: OutlinedButton.styleFrom(foregroundColor: _smAmber))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(onPressed: _actionBusy ? null : () => _powerAction(reboot: false), icon: const Icon(Icons.power_settings_new_rounded), label: const Text('إيقاف التشغيل'), style: OutlinedButton.styleFrom(foregroundColor: _smRed))),
            ]),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          const Expanded(child: Text('ملفات الراوتر (/file/print)', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900))),
          IconButton(onPressed: _loadFiles, icon: const Icon(Icons.refresh_rounded, color: _smAccent)),
        ]),
        if (_error != null) Text(_error!, style: const TextStyle(color: _smRed)),
        if (_files.isEmpty) const _SmEmpty(text: 'لا توجد ملفات أو لم يتمكن الراوتر من إرجاعها.'),
        ..._files.map((file) {
          final name = file['name'] ?? '(بدون اسم)';
          final size = _fileSize(file['size'] ?? '');
          final type = file['type'] ?? '';
          return Card(color: _smPanel, child: ListTile(
            leading: Icon(name.endsWith('.backup') ? Icons.inventory_2_rounded : name.endsWith('.rsc') ? Icons.description_rounded : Icons.insert_drive_file_outlined, color: _smAccent),
            title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 12), textDirection: TextDirection.ltr),
            subtitle: Text([size, type, if ((file['creation-time'] ?? '').isNotEmpty) file['creation-time']!].where((v) => v.isNotEmpty).join(' · '), style: const TextStyle(color: _smMuted, fontSize: 10)),
          ));
        }),
      ]),
    );
  }
}

class _SmHeader extends StatelessWidget {
  const _SmHeader({required this.title, required this.subtitle, required this.count, required this.refresh});
  final String title, subtitle;
  final int count;
  final Future<void> Function() refresh;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF292647), Color(0xFF111722)]), borderRadius: BorderRadius.circular(15)),
    child: Row(children: [
      const Icon(Icons.settings_suggest_rounded, color: _smAccent),
      const SizedBox(width: 9),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13)),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: _smMuted, fontSize: 10)),
      ])),
      Text(count.toString(), style: const TextStyle(color: _smGreen, fontWeight: FontWeight.w900)),
      IconButton(onPressed: refresh, icon: const Icon(Icons.refresh_rounded, color: _smAccent)),
    ]),
  );
}

class _SmPill extends StatelessWidget {
  const _SmPill({required this.label, this.color = _smMuted});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
    child: Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700)),
  );
}

class _SmEmpty extends StatelessWidget {
  const _SmEmpty({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(22), child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: _smMuted, fontSize: 11)));
}

class _SmRetry extends StatelessWidget {
  const _SmRetry({required this.title, required this.error, required this.retry});
  final String title, error;
  final Future<void> Function() retry;
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(22), child: Column(mainAxisSize: MainAxisSize.min, children: [
    Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
    const SizedBox(height: 8),
    Text(error, textAlign: TextAlign.center, style: const TextStyle(color: _smMuted)),
    TextButton.icon(onPressed: retry, icon: const Icon(Icons.refresh_rounded), label: const Text('إعادة المحاولة')),
  ])));
}

void _smMessage(BuildContext context, String message, {bool isError = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: isError ? _smRed : const Color(0xFF202839)));
}

String _smFriendly(Object error) {
  if (error is TimeoutException) return 'انتهت مهلة الاتصال بالراوتر.';
  if (error is RouterOsException) return error.message;
  return error.toString().replaceFirst('Exception: ', '');
}
