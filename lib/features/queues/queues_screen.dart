import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _qPanel = Color(0xFF111722);
const Color _qMuted = Color(0xFF8D9AB0);
const Color _qAccent = Color(0xFF8B7CFF);
const Color _qGreen = Color(0xFF43D9A3);
const Color _qRed = Color(0xFFFF657A);
const Color _qBlue = Color(0xFF67B7FF);

class QueuesScreen extends ConsumerWidget {
  const QueuesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Center(child: Text('اتصل براوتر أولًا.'));
    return QueuesWorkspace(client: client);
  }
}

class QueuesWorkspace extends StatefulWidget {
  const QueuesWorkspace({super.key, required this.client});
  final RouterOsClient client;

  @override
  State<QueuesWorkspace> createState() => _QueuesWorkspaceState();
}

class _QueuesWorkspaceState extends State<QueuesWorkspace> {
  List<_SimpleQueue> _queues = <_SimpleQueue>[];
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  Timer? _timer;
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && !_refreshing) unawaited(_load(silent: true));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final rows = await widget.client.command(
        '/queue/simple/print',
        args: const <String, String>{
          'stats': '',
          '.proplist': '.id,name,target,max-limit,rate,bytes,packets,disabled,comment',
        },
      );
      final queues = rows.map(_SimpleQueue.fromMap).where((item) => item.id.isNotEmpty || item.name.isNotEmpty).toList(growable: false)
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _queues = queues;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendly(error);
      });
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _addQueue() async {
    final form = await _queueDialog();
    if (form == null) return;
    try {
      await widget.client.command('/queue/simple/add', args: form);
      _show('تمت إضافة الطابور: ' + form['name']!);
      await _load();
    } catch (error) {
      _show('تعذرت إضافة الطابور: ' + _friendly(error), isError: true);
    }
  }

  Future<Map<String, String>?> _queueDialog({_SimpleQueue? queue}) async {
    final name = TextEditingController(text: queue?.name ?? '');
    final target = TextEditingController(text: queue?.target ?? '');
    final speed = TextEditingController(text: queue?.maxLimit ?? '10M/10M');
    final comment = TextEditingController(text: queue?.comment ?? '');
    final key = GlobalKey<FormState>();
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _qPanel,
        title: Text(queue == null ? 'إضافة طابور سرعة' : 'تعديل سرعة ' + queue.name, style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Form(
            key: key,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextFormField(
                controller: name,
                enabled: queue == null,
                decoration: const InputDecoration(labelText: 'اسم الطابور'),
                validator: (value) => value == null || value.trim().isEmpty ? 'اسم الطابور مطلوب' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: target,
                decoration: const InputDecoration(labelText: 'Target (IP أو شبكة)'),
                validator: (value) => value == null || value.trim().isEmpty ? 'أدخل Target' : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: speed,
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(labelText: 'Max limit (رفع/تنزيل)', hintText: '10M/10M'),
                validator: (value) => value == null || !_validLimit(value.trim()) ? 'مثال صحيح: 10M/10M أو 512k/5M' : null,
              ),
              const SizedBox(height: 10),
              TextField(controller: comment, decoration: const InputDecoration(labelText: 'ملاحظة (اختياري)')),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              if (key.currentState?.validate() ?? false) {
                Navigator.pop(dialogContext, <String, String>{
                  'name': name.text.trim(),
                  'target': target.text.trim(),
                  'max-limit': speed.text.trim(),
                  if (comment.text.trim().isNotEmpty) 'comment': comment.text.trim(),
                });
              }
            },
            child: Text(queue == null ? 'إضافة' : 'حفظ'),
          ),
        ],
      ),
    );
    name.dispose();
    target.dispose();
    speed.dispose();
    comment.dispose();
    return result;
  }

  Future<void> _editQueue(_SimpleQueue queue) async {
    if (queue.id.isEmpty) return;
    final form = await _queueDialog(queue: queue);
    if (form == null) return;
    await _mutate(queue, () async {
      await widget.client.command('/queue/simple/set', args: <String, String>{
        '.id': queue.id,
        'target': form['target']!,
        'max-limit': form['max-limit']!,
        'comment': form['comment'] ?? '',
      });
    }, 'تم تحديث سرعة ' + queue.name);
  }

  Future<void> _toggle(_SimpleQueue queue) async {
    if (queue.id.isEmpty) return;
    await _mutate(queue, () async {
      await widget.client.command('/queue/simple/set', args: <String, String>{
        '.id': queue.id,
        'disabled': queue.disabled ? 'no' : 'yes',
      });
    }, queue.disabled ? 'تم تفعيل الطابور' : 'تم تعطيل الطابور');
  }

  Future<void> _mutate(_SimpleQueue queue, Future<void> Function() action, String success) async {
    if (_busy.contains(queue.id)) return;
    setState(() => _busy.add(queue.id));
    try {
      await action();
      if (!mounted) return;
      _show(success);
      await _load();
    } catch (error) {
      if (mounted) _show(_friendly(error), isError: true);
    } finally {
      if (mounted) setState(() => _busy.remove(queue.id));
    }
  }

  void _show(String text, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: isError ? _qRed.withOpacity(0.95) : const Color(0xFF202839),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _queues.isEmpty) return const Center(child: CircularProgressIndicator(color: _qAccent));
    if (_error != null && _queues.isEmpty) {
      return _QueueMessage(title: 'تعذر تحميل الطوابير', message: _error!, onRetry: () => _load());
    }
    return RefreshIndicator(
      color: _qAccent,
      backgroundColor: _qPanel,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
        children: [
          Container(
            padding: const EdgeInsets.all(15),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF292647), Color(0xFF111722)]),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _qAccent.withOpacity(0.22)),
            ),
            child: Row(children: [
              const Icon(Icons.speed_rounded, color: _qAccent, size: 26),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Simple Queues', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                const Text('قراءة إحصاءات السرعة كل 3 ثوانٍ', style: TextStyle(color: _qMuted, fontSize: 10)),
                const SizedBox(height: 3),
                Text('/queue/simple/print stats', textDirection: TextDirection.ltr, style: const TextStyle(color: _qMuted, fontSize: 9)),
              ])),
              Text(_queues.length.toString(), style: const TextStyle(color: _qGreen, fontSize: 23, fontWeight: FontWeight.w900)),
            ]),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: _QueueStat(label: 'الطوابير الفعّالة', value: _queues.where((q) => !q.disabled).length.toString(), color: _qGreen)),
            const SizedBox(width: 8),
            Expanded(child: _QueueStat(label: 'عند الحد', value: _queues.where((q) => q.atLimit).length.toString(), color: _qRed)),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text('تعذّر تحديث آخر قراءة: ' + _error!, style: const TextStyle(color: _qRed, fontSize: 11)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _addQueue,
              icon: const Icon(Icons.add_rounded),
              label: const Text('إضافة طابور جديد'),
            ),
          ),
          const SizedBox(height: 12),
          if (_queues.isEmpty)
            const _QueueMessage(title: 'لا توجد طوابير', message: 'أضف Simple Queue لمتابعة السرعة وتعديل max-limit.')
          else
            ..._queues.map((queue) => Container(
                  margin: const EdgeInsets.only(bottom: 9),
                  decoration: BoxDecoration(
                    color: _qPanel,
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: queue.atLimit && !queue.disabled ? _qRed.withOpacity(0.72) : Colors.white.withOpacity(0.055), width: queue.atLimit && !queue.disabled ? 1.3 : 1),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(13),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Container(
                          width: 37,
                          height: 37,
                          decoration: BoxDecoration(color: (queue.disabled ? _qMuted : (queue.atLimit ? _qRed : _qGreen)).withOpacity(0.13), borderRadius: BorderRadius.circular(11)),
                          child: Icon(queue.disabled ? Icons.pause_circle_outline_rounded : Icons.speed_rounded, color: queue.disabled ? _qMuted : (queue.atLimit ? _qRed : _qGreen)),
                        ),
                        const SizedBox(width: 9),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(queue.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 3),
                          Text(queue.target.isEmpty ? 'Target غير محدد' : queue.target, textDirection: TextDirection.ltr, style: const TextStyle(color: _qMuted, fontSize: 10)),
                        ])),
                        if (queue.atLimit && !queue.disabled)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            decoration: BoxDecoration(color: _qRed.withOpacity(0.13), borderRadius: BorderRadius.circular(8)),
                            child: const Text('عند الحد', style: TextStyle(color: _qRed, fontSize: 10, fontWeight: FontWeight.w900)),
                          ),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: _QueueRate(label: 'السحب RX', value: _rateLabel(queue.rateDown), color: _qBlue)),
                        const SizedBox(width: 8),
                        Expanded(child: _QueueRate(label: 'الرفع TX', value: _rateLabel(queue.rateUp), color: _qGreen)),
                      ]),
                      const SizedBox(height: 10),
                      Row(children: [
                        const Icon(Icons.tune_rounded, size: 15, color: _qMuted),
                        const SizedBox(width: 6),
                        Expanded(child: Text('Max limit: ' + (queue.maxLimit.isEmpty ? 'غير محدد' : queue.maxLimit), textDirection: TextDirection.ltr, style: const TextStyle(color: _qMuted, fontSize: 10))),
                        Text(_bytesLabel(queue.bytes), style: const TextStyle(color: _qMuted, fontSize: 10)),
                      ]),
                      if (queue.packets > 0) ...[
                        const SizedBox(height: 4),
                        Text('Packets: ' + queue.packets.toString(), style: const TextStyle(color: _qMuted, fontSize: 9)),
                      ],
                      const Divider(height: 20, color: Color(0xFF283142)),
                      Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy.contains(queue.id) ? null : () => _editQueue(queue),
                            icon: const Icon(Icons.edit_rounded, size: 16),
                            label: const Text('تعديل السرعة'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: _busy.contains(queue.id) ? null : () => _toggle(queue),
                            icon: _busy.contains(queue.id) ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(queue.disabled ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 16),
                            label: Text(queue.disabled ? 'تفعيل' : 'تعطيل'),
                            style: FilledButton.styleFrom(foregroundColor: queue.disabled ? _qGreen : _qRed),
                          ),
                        ),
                      ]),
                    ]),
                  ),
                )),
        ],
      ),
    );
  }
}

class _SimpleQueue {
  const _SimpleQueue({
    required this.id,
    required this.name,
    required this.target,
    required this.maxLimit,
    required this.rate,
    required this.disabled,
    required this.bytes,
    required this.packets,
    required this.comment,
  });

  final String id;
  final String name;
  final String target;
  final String maxLimit;
  final String rate;
  final bool disabled;
  final int bytes;
  final int packets;
  final String comment;

  double get rateUp => _pair(rate, 0);
  double get rateDown => _pair(rate, 1);
  bool get atLimit {
    if (disabled) return false;
    final upMax = _pair(maxLimit, 0);
    final downMax = _pair(maxLimit, 1);
    final currentUp = rateUp;
    final currentDown = rateDown;
    return (upMax > 0 && currentUp >= upMax * 0.97) || (downMax > 0 && currentDown >= downMax * 0.97);
  }

  factory _SimpleQueue.fromMap(Map<String, String> row) => _SimpleQueue(
        id: row['.id'] ?? '',
        name: row['name'] ?? 'Queue',
        target: row['target'] ?? '',
        maxLimit: row['max-limit'] ?? '',
        rate: row['rate'] ?? '',
        disabled: row['disabled'] == 'true',
        bytes: _integerPairSum(row['bytes'] ?? ''),
        packets: _integerPairSum(row['packets'] ?? ''),
        comment: row['comment'] ?? '',
      );
}

double _pair(String value, int index) {
  final parts = value.split('/');
  if (parts.length <= index) return 0;
  final match = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*([kKmMgGtT]?)\s*$').firstMatch(parts[index]);
  if (match == null) return 0;
  final number = double.tryParse(match.group(1) ?? '') ?? 0;
  final unit = (match.group(2) ?? '').toLowerCase();
  final multiplier = unit == 'k' ? 1000.0 : unit == 'm' ? 1000000.0 : unit == 'g' ? 1000000000.0 : unit == 't' ? 1000000000000.0 : 1.0;
  return number * multiplier;
}

int _integerPairSum(String value) => value.split('/').fold<int>(0, (sum, part) => sum + (int.tryParse(part) ?? 0));

String _rateLabel(double bitsPerSecond) {
  if (bitsPerSecond >= 1000000000) return (bitsPerSecond / 1000000000).toStringAsFixed(2) + ' Gbps';
  if (bitsPerSecond >= 1000000) return (bitsPerSecond / 1000000).toStringAsFixed(2) + ' Mbps';
  if (bitsPerSecond >= 1000) return (bitsPerSecond / 1000).toStringAsFixed(1) + ' Kbps';
  return bitsPerSecond.toStringAsFixed(0) + ' bps';
}

String _bytesLabel(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1) + ' GB';
  if (bytes >= 1024 * 1024) return (bytes / (1024 * 1024)).toStringAsFixed(1) + ' MB';
  if (bytes >= 1024) return (bytes / 1024).toStringAsFixed(1) + ' KB';
  return bytes.toString() + ' B';
}

bool _validLimit(String value) => RegExp(r'^\s*\d+(?:[kKmMgGtT]?)\s*\/\s*\d+(?:[kKmMgGtT]?)\s*$').hasMatch(value);

class _QueueRate extends StatelessWidget {
  const _QueueRate({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(11)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: _qMuted, fontSize: 9)),
          const SizedBox(height: 4),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 12)),
        ]),
      );
}

class _QueueStat extends StatelessWidget {
  const _QueueStat({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: _qPanel, borderRadius: BorderRadius.circular(13)),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(color: _qMuted, fontSize: 10))),
          Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w900)),
        ]),
      );
}

class _QueueMessage extends StatelessWidget {
  const _QueueMessage({required this.title, required this.message, this.onRetry});
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.speed_rounded, color: _qAccent, size: 38),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: _qMuted, fontSize: 12, height: 1.5)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
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
