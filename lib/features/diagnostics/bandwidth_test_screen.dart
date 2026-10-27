import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/router_providers.dart';

const Color _bandBg = Color(0xFF080B12);
const Color _bandPanel = Color(0xFF111722);
const Color _bandMuted = Color(0xFF8D9AB0);
const Color _bandAccent = Color(0xFF8B7CFF);
const Color _bandRx = Color(0xFF43D9A3);
const Color _bandTx = Color(0xFF67B7FF);
const Color _bandRed = Color(0xFFFF657A);

class BandwidthTestScreen extends ConsumerStatefulWidget {
  const BandwidthTestScreen({super.key});
  @override
  ConsumerState<BandwidthTestScreen> createState() => _BandwidthTestScreenState();
}

class _BandwidthTestScreenState extends ConsumerState<BandwidthTestScreen> {
  final TextEditingController _address = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  StreamSubscription<Map<String, String>>? _subscription;
  final List<FlSpot> _rxPoints = <FlSpot>[];
  final List<FlSpot> _txPoints = <FlSpot>[];
  String _protocol = 'tcp';
  String _direction = 'both';
  String _duration = '00:00:30';
  String _status = 'جاهز لبدء الاختبار';
  String? _error;
  bool _running = false;
  bool _busy = false;
  int _sample = 0;
  double _rxMbps = 0;
  double _txMbps = 0;

  @override
  void dispose() {
    final subscription = _subscription;
    if (subscription != null) unawaited(subscription.cancel());
    _address.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  double? _parseRate(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.trim().toLowerCase().replaceAll(',', '');
    final match = RegExp(r'^(-?[0-9]+(?:\.[0-9]+)?)\s*([a-z/]+)?$').firstMatch(value);
    if (match == null) return double.tryParse(value);
    final number = double.tryParse(match.group(1)!);
    if (number == null) return null;
    final unit = match.group(2) ?? '';
    if (unit.contains('gbit') || unit == 'gbps') return number * 1000;
    if (unit.contains('mbit') || unit == 'mbps') return number;
    if (unit.contains('kbit') || unit == 'kbps') return number / 1000;
    if (unit.isEmpty || unit == 'bps' || unit == 'bit/s' || unit == 'bits/s') return number / 1000000;
    return number;
  }

  double _rate(Map<String, String> row, List<String> keys) {
    for (final key in keys) {
      final rate = _parseRate(row[key]);
      if (rate != null) return rate.isFinite && rate > 0 ? rate : 0;
    }
    return 0;
  }

  void _onSample(Map<String, String> row) {
    final rx = _rate(row, const <String>['rx-current', 'rx-10-second-average', 'rx-total-average', 'rx-current-speed']);
    final tx = _rate(row, const <String>['tx-current', 'tx-10-second-average', 'tx-total-average', 'tx-current-speed']);
    if (!mounted) return;
    setState(() {
      _rxMbps = rx;
      _txMbps = tx;
      _status = row['status'] ?? row['state'] ?? 'الاختبار يعمل';
      _error = null;
      _rxPoints.add(FlSpot(_sample.toDouble(), rx));
      _txPoints.add(FlSpot(_sample.toDouble(), tx));
      _sample++;
      while (_rxPoints.length > 45) {
        _rxPoints.removeAt(0);
        _txPoints.removeAt(0);
      }
    });
  }

  Future<void> _start() async {
    if (_running || _busy) return;
    final address = _address.text.trim();
    final username = _username.text.trim();
    final password = _password.text;
    if (address.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = 'أدخل عنوان الراوتر البعيد واسم المستخدم وكلمة المرور.');
      return;
    }
    final client = ref.read(activeRouterClientProvider);
    if (client == null) {
      setState(() => _error = 'اتصل براوتر الإدارة أولاً.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = 'جارٍ بدء اختبار عرض النطاق...';
      _rxMbps = 0;
      _txMbps = 0;
      _sample = 0;
      _rxPoints.clear();
      _txPoints.clear();
    });
    try {
      final stream = client.monitorStream('/tool/bandwidth-test', args: <String, String>{
        'address': address,
        'user': username,
        'password': password,
        'protocol': _protocol,
        'direction': _direction,
        'duration': _duration,
      });
      _subscription = stream.listen(
        _onSample,
        onError: (Object error, StackTrace stack) {
          if (mounted) setState(() {
            _running = false;
            _busy = false;
            _error = error.toString().replaceFirst('RouterOsException: ', '');
            _status = 'توقف الاختبار بسبب خطأ';
          });
        },
        onDone: () {
          if (mounted) setState(() {
            _running = false;
            _busy = false;
            if (_error == null) _status = 'انتهى الاختبار';
          });
        },
        cancelOnError: true,
      );
      if (mounted) setState(() {
        _running = true;
        _busy = false;
        _status = 'الاختبار جارٍ';
      });
    } catch (error) {
      if (mounted) setState(() {
        _busy = false;
        _running = false;
        _error = error.toString().replaceFirst('RouterOsException: ', '');
        _status = 'تعذر بدء الاختبار';
      });
    }
  }

  Future<void> _stop() async {
    if (!_running && _subscription == null) return;
    setState(() { _busy = true; _status = 'جارٍ إيقاف الاختبار...'; });
    final current = _subscription;
    _subscription = null;
    try {
      await current?.cancel();
    } catch (_) {
      // Keep the local state stopped even if the router disconnects.
    }
    if (mounted) setState(() {
      _running = false;
      _busy = false;
      _status = 'أوقف المستخدم الاختبار';
    });
  }

  Widget _panel(String title, Widget child) => Container(
    width: double.infinity, margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: _bandPanel, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white.withOpacity(.06))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12), child,
    ]),
  );

  Widget _rateCard(String title, double value, Color color, IconData icon) => Expanded(child: Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(13), border: Border.all(color: color.withOpacity(.25))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 20),
      const SizedBox(height: 9),
      Text(value.toStringAsFixed(2), style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.w900, fontFamily: 'monospace')),
      const Text('Mbps', style: TextStyle(color: _bandMuted, fontSize: 10)),
      const SizedBox(height: 4), Text(title, style: const TextStyle(color: Colors.white, fontSize: 11)),
    ]),
  ));

  Widget _speedChart() {
    final allValues = <double>[..._rxPoints.map((point) => point.y), ..._txPoints.map((point) => point.y)];
    final largest = allValues.fold<double>(0, (current, value) => math.max(current, value));
    final maxY = largest <= 0 ? 1.0 : largest * 1.15;
    final maxX = math.max(1, _sample - 1).toDouble();
    return LineChart(LineChartData(
      minX: _rxPoints.isEmpty ? 0 : _rxPoints.first.x,
      maxX: maxX,
      minY: 0,
      maxY: maxY,
      gridData: const FlGridData(show: false),
      titlesData: const FlTitlesData(show: false),
      borderData: FlBorderData(show: false),
      lineTouchData: const LineTouchData(enabled: true),
      lineBarsData: <LineChartBarData>[
        LineChartBarData(spots: _rxPoints.isEmpty ? <FlSpot>[const FlSpot(0, 0)] : _rxPoints, isCurved: true, color: _bandRx, barWidth: 2, dotData: const FlDotData(show: false)),
        LineChartBarData(spots: _txPoints.isEmpty ? <FlSpot>[const FlSpot(0, 0)] : _txPoints, isCurved: true, color: _bandTx, barWidth: 2, dotData: const FlDotData(show: false)),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Scaffold(backgroundColor: _bandBg, body: Center(child: Text('اتصل براوتر الإدارة أولاً.', style: TextStyle(color: Colors.white))));
    return Scaffold(
      backgroundColor: _bandBg,
      appBar: AppBar(
        backgroundColor: _bandBg, foregroundColor: Colors.white, title: const Text('Bandwidth Test'),
        actions: [IconButton(onPressed: _running || _busy ? null : () => setState(() { _error = null; _status = 'جاهز لبدء الاختبار'; }), icon: const Icon(Icons.refresh_rounded))],
      ),
      body: ListView(padding: const EdgeInsets.all(13), children: [
        _panel('الراوتر الطرف الآخر', Column(children: [
          TextField(controller: _address, enabled: !_running, keyboardType: TextInputType.url, style: const TextStyle(color: Colors.white, fontFamily: 'monospace'), decoration: const InputDecoration(labelText: 'Remote Router IP / DNS', hintText: '192.168.1.2')),
          const SizedBox(height: 9),
          TextField(controller: _username, enabled: !_running, autocorrect: false, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'اسم المستخدم')),
          const SizedBox(height: 9),
          TextField(controller: _password, enabled: !_running, obscureText: true, autocorrect: false, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'كلمة المرور')),
          const SizedBox(height: 9),
          DropdownButtonFormField<String>(
            initialValue: _protocol, decoration: const InputDecoration(labelText: 'Protocol'), dropdownColor: _bandPanel, style: const TextStyle(color: Colors.white),
            items: const [DropdownMenuItem(value: 'tcp', child: Text('TCP')), DropdownMenuItem(value: 'udp', child: Text('UDP'))],
            onChanged: _running ? null : (value) => setState(() => _protocol = value ?? _protocol),
          ),
          const SizedBox(height: 9),
          DropdownButtonFormField<String>(
            initialValue: _direction, decoration: const InputDecoration(labelText: 'Direction'), dropdownColor: _bandPanel, style: const TextStyle(color: Colors.white),
            items: const [
              DropdownMenuItem(value: 'receive', child: Text('Receive')),
              DropdownMenuItem(value: 'transmit', child: Text('Transmit')),
              DropdownMenuItem(value: 'both', child: Text('Both directions')),
            ],
            onChanged: _running ? null : (value) => setState(() => _direction = value ?? _direction),
          ),
          const SizedBox(height: 9),
          DropdownButtonFormField<String>(
            initialValue: _duration, decoration: const InputDecoration(labelText: 'مدة الاختبار'), dropdownColor: _bandPanel, style: const TextStyle(color: Colors.white),
            items: const [
              DropdownMenuItem(value: '00:00:10', child: Text('10 ثوانٍ')),
              DropdownMenuItem(value: '00:00:30', child: Text('30 ثانية')),
              DropdownMenuItem(value: '00:01:00', child: Text('60 ثانية')),
            ],
            onChanged: _running ? null : (value) => setState(() => _duration = value ?? _duration),
          ),
          const SizedBox(height: 13),
          Row(children: [
            Expanded(child: FilledButton.icon(onPressed: _running || _busy ? null : _start, icon: const Icon(Icons.play_arrow_rounded), label: const Text('بدء الاختبار'))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton.icon(onPressed: _running && !_busy ? _stop : null, icon: const Icon(Icons.stop_rounded), label: const Text('إيقاف'))),
          ]),
        ])),
        if (_error != null) _panel('خطأ', Text(_error!, style: const TextStyle(color: _bandRed, fontSize: 12, height: 1.45))),
        _panel('السرعة الحية', Column(children: [
          Row(children: [
            _rateCard('Receive / RX', _rxMbps, _bandRx, Icons.south_rounded),
            const SizedBox(width: 10),
            _rateCard('Transmit / TX', _txMbps, _bandTx, Icons.north_rounded),
          ]),
          const SizedBox(height: 12),
          Container(width: double.infinity, padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(10)), child: Row(children: [
            Icon(_running ? Icons.sensors_rounded : Icons.info_outline_rounded, color: _running ? _bandRx : _bandMuted),
            const SizedBox(width: 8), Expanded(child: Text(_status, style: const TextStyle(color: Colors.white, fontSize: 12))),
          ])),
          const SizedBox(height: 12),
          SizedBox(height: 185, child: _speedChart()),
          const Row(children: [
            Icon(Icons.circle, color: _bandRx, size: 8), SizedBox(width: 5), Text('RX Mbps', style: TextStyle(color: _bandMuted, fontSize: 10)),
            SizedBox(width: 15), Icon(Icons.circle, color: _bandTx, size: 8), SizedBox(width: 5), Text('TX Mbps', style: TextStyle(color: _bandMuted, fontSize: 10)),
          ]),
        ])),
        const Padding(
          padding: EdgeInsets.fromLTRB(5, 0, 5, 18),
          child: Text('يجب تفعيل Bandwidth Server على الراوتر الطرف الآخر والسماح بالوصول إليه. بيانات الدخول تُستخدم للاختبار الحالي فقط ولا تُحفظ داخل التطبيق.', style: TextStyle(color: _bandMuted, fontSize: 11, height: 1.5)),
        ),
      ]),
    );
  }
}
