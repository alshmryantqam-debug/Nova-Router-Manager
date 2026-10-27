import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _consoleBg = Color(0xFF030507);
const Color _consolePanel = Color(0xFF0B1017);
const Color _consoleGreen = Color(0xFF5CE0A1);
const Color _consoleBlue = Color(0xFF69B8FF);
const Color _consoleMuted = Color(0xFF8995A8);
const Color _consoleRed = Color(0xFFFF6D7C);

class ApiTerminalScreen extends ConsumerStatefulWidget {
  const ApiTerminalScreen({super.key});

  @override
  ConsumerState<ApiTerminalScreen> createState() => _ApiTerminalScreenState();
}

class _ApiTerminalScreenState extends ConsumerState<ApiTerminalScreen> {
  RouterOsClient? _client;
  final _pathController = TextEditingController(text: '/ip/address/print');
  final _argsController = TextEditingController(text: '.proplist=address,network,interface,disabled');
  final ScrollController _outputScroll = ScrollController();
  final List<_CommandRecord> _history = [];
  bool _running = false;
  int _sequence = 0;

  @override
  void initState() {
    super.initState();
    _client = ref.read(activeRouterClientProvider);
  }

  @override
  void dispose() {
    _pathController.dispose();
    _argsController.dispose();
    _outputScroll.dispose();
    super.dispose();
  }

  String _normalisePath(String raw) {
    final value = raw.trim().replaceAll(RegExp(r'\s+'), '/').replaceAll(RegExp(r'/+'), '/');
    if (value.isEmpty || !value.startsWith('/')) {
      throw const FormatException('المسار يجب أن يبدأ بـ / مثل /ip/address/print');
    }
    return value;
  }

  Map<String, String> _parseArgs(String source) {
    final result = <String, String>{};
    for (final rawLine in source.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final splitAt = line.indexOf('=');
      if (splitAt < 1) {
        throw FormatException('صيغة المعامل غير صحيحة: $line\nاكتب key=value، كل معامل بسطر.');
      }
      var key = line.substring(0, splitAt).trim();
      final value = line.substring(splitAt + 1).trim();
      if (key.isEmpty || key.contains(RegExp(r'\s'))) {
        throw FormatException('اسم المعامل غير صالح: $key');
      }
      result[key] = value;
    }
    return result;
  }

  bool _mayChangeConfiguration(String path) {
    final p = path.toLowerCase();
    return RegExp(r'/(add|set|remove|enable|disable|move|reset|reboot|upgrade|run|flush|clear|renew|release|create|delete|make-static)$').hasMatch(p) ||
        p.contains('/reset-configuration') || p.contains('/system/reboot') ||
        p.contains('/system/shutdown') || p.contains('/certificate/import') ||
        p.contains('/backup/save') || p.contains('/export');
  }

  Future<bool> _confirmCommand(String path) async {
    return await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _consolePanel,
        title: const Text('تأكيد تنفيذ الأمر', style: TextStyle(color: Colors.white)),
        content: Text('المسار التالي قد يغيّر إعدادات الراوتر أو يمسح بيانات تشغيلية:\n\n$path\n\nلن يُنفّذ قبل تأكيدك.',
          style: const TextStyle(color: _consoleMuted)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('تنفيذ الأمر')),
        ],
      ),
    ) ?? false;
  }

  Future<void> _runCommand({String? path, Map<String, String>? args}) async {
    final client = _client;
    if (client == null) {
      _showMessage('لا يوجد راوتر متصل.', isError: true);
      return;
    }
    if (_running) return;
    late final String commandPath;
    late final Map<String, String> commandArgs;
    try {
      commandPath = _normalisePath(path ?? _pathController.text);
      commandArgs = args ?? _parseArgs(_argsController.text);
    } catch (e) {
      _showMessage(e.toString().replaceFirst('FormatException: ', ''), isError: true);
      return;
    }
    if (_mayChangeConfiguration(commandPath)) {
      final approved = await _confirmCommand(commandPath);
      if (!approved || !mounted) return;
    }
    if (path != null) {
      _pathController.text = commandPath;
      _argsController.text = commandArgs.isEmpty
          ? ''
          : commandArgs.entries.map((e) => '${e.key}=${e.value}').join('\n');
    }
    final started = DateTime.now();
    final record = _CommandRecord(
      id: ++_sequence, path: commandPath, arguments: Map<String, String>.from(commandArgs),
      output: '', isError: false, elapsed: Duration.zero, time: started,
    );
    setState(() { _running = true; _history.insert(0, record); });
    try {
      final rows = await client.command(commandPath, args: commandArgs, timeout: const Duration(seconds: 30));
      final output = rows.isEmpty
          ? 'تم تنفيذ الأمر بنجاح.\nالراوتر لم يُرجع صفوف بيانات (هذا طبيعي لأوامر التنفيذ).'
          : const JsonEncoder.withIndent('  ').convert(rows);
      _replaceRecord(record.id, output: output, elapsed: DateTime.now().difference(started));
    } catch (e) {
      _replaceRecord(record.id, output: 'ROUTEROS API ERROR\n${e.toString()}',
        isError: true, elapsed: DateTime.now().difference(started));
    } finally {
      if (mounted) {
        setState(() => _running = false);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (_outputScroll.hasClients) {
          await _outputScroll.animateTo(_outputScroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
        }
      }
    }
  }

  void _replaceRecord(int id, {required String output, bool? isError, required Duration elapsed}) {
    final index = _history.indexWhere((entry) => entry.id == id);
    if (index < 0) return;
    setState(() {
      _history[index] = _history[index].copyWith(output: output, isError: isError, elapsed: elapsed);
      if (_history.length > 30) _history.removeRange(30, _history.length);
    });
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: isError ? const Color(0xFF8C3042) : const Color(0xFF176D58),
    ));
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showMessage('تم نسخ النص إلى الحافظة.');
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null || !identical(client, _client)) {
      return const Scaffold(backgroundColor: _consoleBg, body: Center(
        child: Text('اتصل بالراوتر أولاً ثم افتح CLI / API Console.', style: TextStyle(color: Colors.white))));
    }
    return Scaffold(
      backgroundColor: _consoleBg,
      appBar: AppBar(
        backgroundColor: _consoleBg,
        foregroundColor: Colors.white,
        title: const Text('CLI / API Console', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(tooltip: 'نسخ آخر رد', onPressed: _history.isEmpty ? null : () => _copy(_history.first.output),
            icon: const Icon(Icons.copy_all_rounded)),
          IconButton(tooltip: 'مسح السجل الظاهر', onPressed: _history.isEmpty ? null : () => setState(_history.clear),
            icon: const Icon(Icons.delete_sweep_outlined)),
        ],
      ),
      body: Column(children: [
        Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: _consolePanel, borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF273143))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('أوامر سريعة', style: TextStyle(color: _consoleMuted, fontSize: 11, fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 2, children: [
              _quickChip('فحص DNS', Icons.dns_outlined, () => _runCommand(path: '/ip/dns/print', args: const {})),
              _quickChip('عناوين IP', Icons.route_outlined, () => _runCommand(path: '/ip/address/print', args: const {})),
              _quickChip('Flush DNS Cache', Icons.cleaning_services_outlined, () => _runCommand(path: '/ip/dns/cache/flush', args: const {})),
              _quickChip('جدول ARP', Icons.device_hub_outlined, () => _runCommand(path: '/ip/arp/print', args: const {})),
            ]),
          ]),
        ),
        Expanded(child: ListView(
          controller: _outputScroll,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _consolePanel, borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _consoleGreen.withOpacity(.28))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Row(children: [
                  Icon(Icons.terminal_rounded, color: _consoleGreen, size: 20),
                  SizedBox(width: 8),
                  Text('أدخل مسار RouterOS API', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: _pathController,
                  style: const TextStyle(color: _consoleGreen, fontFamily: 'monospace', fontSize: 13),
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(labelText: 'Command path', hintText: '/ip/firewall/nat/print',
                    prefixText: '> ', prefixStyle: TextStyle(color: _consoleGreen, fontFamily: 'monospace')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _argsController,
                  minLines: 2,
                  maxLines: 5,
                  style: const TextStyle(color: _consoleBlue, fontFamily: 'monospace', fontSize: 12),
                  textDirection: TextDirection.ltr,
                  decoration: const InputDecoration(labelText: 'المعاملات (key=value، كل معامل بسطر)',
                    hintText: '.proplist=name,address\ninterface=ether1', alignLabelWithHint: true),
                ),
                const SizedBox(height: 6),
                const Text('الأوامر التي قد تغيّر الإعدادات تتطلب تأكيداً إضافياً.', style: TextStyle(color: _consoleMuted, fontSize: 10)),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: FilledButton.icon(
                  onPressed: _running ? null : () => _runCommand(),
                  icon: _running
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow_rounded),
                  label: Text(_running ? 'جارٍ انتظار الرد...' : 'تنفيذ على الراوتر'),
                )),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              const Expanded(child: Text('سجل الأوامر والردود', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800))),
              Text('${_history.length} سجل', style: const TextStyle(color: _consoleMuted, fontSize: 11)),
            ]),
            const SizedBox(height: 8),
            if (_history.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: Text('لم يتم تنفيذ أوامر بعد.', style: TextStyle(color: _consoleMuted))))
            else
              ..._history.map(_recordCard),
          ],
        )),
      ]),
    );
  }

  Widget _quickChip(String label, IconData icon, VoidCallback onPressed) => ActionChip(
    avatar: Icon(icon, size: 16, color: _consoleGreen),
    label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
    backgroundColor: _consolePanel,
    side: const BorderSide(color: Color(0xFF273143)),
    onPressed: _running ? null : onPressed,
  );

  Widget _recordCard(_CommandRecord item) => Container(
    margin: const EdgeInsets.only(bottom: 10),
    decoration: BoxDecoration(color: _consolePanel, borderRadius: BorderRadius.circular(12),
      border: Border.all(color: item.isError ? _consoleRed.withOpacity(.5) : const Color(0xFF273143))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(11, 10, 6, 8), child: Row(children: [
        Icon(item.isError ? Icons.error_outline : Icons.chevron_right_rounded,
          size: 18, color: item.isError ? _consoleRed : _consoleGreen),
        const SizedBox(width: 4),
        Expanded(child: SelectableText(item.path,
          style: const TextStyle(color: _consoleGreen, fontFamily: 'monospace', fontWeight: FontWeight.w700, fontSize: 12))),
        IconButton(tooltip: 'نسخ الرد', visualDensity: VisualDensity.compact,
          onPressed: () => _copy(item.output), icon: const Icon(Icons.content_copy, color: _consoleMuted, size: 17)),
      ])),
      if (item.arguments.isNotEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 7),
          child: SelectableText(item.arguments.entries.map((e) => '${e.key}=${e.value}').join('  '),
            style: const TextStyle(color: _consoleBlue, fontFamily: 'monospace', fontSize: 10))),
      const Divider(color: Color(0xFF273143), height: 1),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(item.output.isEmpty ? (item.isError ? 'ERROR' : 'waiting for response…') : item.output,
                textDirection: TextDirection.ltr,
                style: TextStyle(color: item.isError ? _consoleRed : const Color(0xFFD5E0EC),
                  fontFamily: 'monospace', fontSize: 11, height: 1.45)),
            ),
          ),
        ),
      ),
      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 9), child: Text(
        '${item.time.toLocal().toString().substring(0, 19)}  •  ${item.elapsed.inMilliseconds} ms',
        textDirection: TextDirection.ltr,
        style: const TextStyle(color: _consoleMuted, fontSize: 9, fontFamily: 'monospace'))),
    ]),
  );
}

class _CommandRecord {
  const _CommandRecord({
    required this.id,
    required this.path,
    required this.arguments,
    required this.output,
    required this.isError,
    required this.elapsed,
    required this.time,
  });

  final int id;
  final String path;
  final Map<String, String> arguments;
  final String output;
  final bool isError;
  final Duration elapsed;
  final DateTime time;

  _CommandRecord copyWith({String? output, bool? isError, Duration? elapsed}) => _CommandRecord(
    id: id, path: path, arguments: arguments, output: output ?? this.output,
    isError: isError ?? this.isError, elapsed: elapsed ?? this.elapsed, time: time);
}
