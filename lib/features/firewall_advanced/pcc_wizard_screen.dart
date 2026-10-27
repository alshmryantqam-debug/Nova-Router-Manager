import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const Color _pccBg = Color(0xFF080B12);
const Color _pccPanel = Color(0xFF111722);
const Color _pccMuted = Color(0xFF8D9AB0);
const Color _pccAccent = Color(0xFF8B7CFF);
const Color _pccGreen = Color(0xFF43D9A3);
const Color _pccRed = Color(0xFFFF657A);

class PccWizardScreen extends ConsumerStatefulWidget {
  const PccWizardScreen({super.key});
  @override
  ConsumerState<PccWizardScreen> createState() => _PccWizardScreenState();
}

class _PccWizardScreenState extends ConsumerState<PccWizardScreen> {
  RouterOsClient? _client;
  List<String> _interfaces = <String>[];
  String? _lanInterface;
  String _classifier = 'both-addresses-and-ports';
  int _wanCount = 2;
  late final String _id = (DateTime.now().millisecondsSinceEpoch % 1000000).toString().padLeft(6, '0');
  final List<_WanForm> _wans = <_WanForm>[_WanForm(), _WanForm()];
  List<_PccCommand>? _commands;
  bool _loading = true;
  bool _applying = false;
  String? _error;
  String? _applyStatus;

  @override
  void initState() {
    super.initState();
    _client = ref.read(activeRouterClientProvider);
    _loadInterfaces();
  }

  @override
  void dispose() {
    for (final wan in _wans) { wan.dispose(); }
    super.dispose();
  }

  String _friendly(Object error) => error.toString().replaceFirst('RouterOsException: ', '').replaceFirst('Exception: ', '');

  Future<void> _loadInterfaces() async {
    final client = ref.read(activeRouterClientProvider);
    if (client == null) {
      if (mounted) setState(() { _loading = false; _error = 'اتصل بالراوتر أولاً.'; });
      return;
    }
    try {
      final rows = await client.command('/interface/print', args: const <String, String>{'.proplist': 'name,type,disabled'});
      final names = rows.map((row) => (row['name'] ?? '').trim()).where((name) => name.isNotEmpty).toSet().toList()..sort();
      if (!mounted) return;
      setState(() {
        _client = client;
        _interfaces = names;
        _lanInterface = names.isEmpty ? null : names.firstWhere((name) => name.toLowerCase().startsWith('bridge'), orElse: () => names.first);
        for (var i = 0; i < _wans.length; i++) {
          if (_wans[i].interfaceName == null && names.isNotEmpty) {
            _wans[i].interfaceName = names.firstWhere((name) => name != _lanInterface, orElse: () => names.first);
          }
        }
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = _friendly(error); });
    }
  }

  void _invalidate() {
    if (_commands != null || _applyStatus != null) {
      setState(() { _commands = null; _applyStatus = null; });
    }
  }

  void _changeWanCount(int count) {
    setState(() {
      if (count > _wans.length) {
        while (_wans.length < count) {
          final wan = _WanForm();
          wan.interfaceName = _interfaces.firstWhere(
            (name) => name != _lanInterface && !_wans.any((existing) => existing.interfaceName == name),
            orElse: () => _interfaces.isEmpty ? '' : _interfaces.first,
          );
          _wans.add(wan);
        }
      } else {
        while (_wans.length > count) { _wans.removeLast().dispose(); }
      }
      _wanCount = count;
      _commands = null;
      _applyStatus = null;
    });
  }

  bool _validIpv4(String value) {
    final parts = value.trim().split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null || number < 0 || number > 255 || part.isEmpty) return false;
    }
    return true;
  }

  String? _validateConfiguration() {
    if (_interfaces.isEmpty) return 'لم يتم تحميل واجهات الراوتر.';
    if (_lanInterface == null || !_interfaces.contains(_lanInterface)) return 'حدد واجهة LAN / Bridge.';
    final selected = <String>[];
    var totalWeight = 0;
    for (var i = 0; i < _wans.length; i++) {
      final wan = _wans[i];
      if (wan.interfaceName == null || !_interfaces.contains(wan.interfaceName)) return 'حدد واجهة WAN رقم ${i + 1}.';
      if (wan.interfaceName == _lanInterface) return 'لا يمكن استخدام واجهة LAN نفسها كخط WAN رقم ${i + 1}.';
      if (selected.contains(wan.interfaceName)) return 'واجهة WAN مكررة: ${wan.interfaceName}.';
      selected.add(wan.interfaceName!);
      if (!_validIpv4(wan.gateway.text)) return 'Gateway IP للخط ${i + 1} غير صالح.';
      final weight = int.tryParse(wan.weight.text.trim());
      if (weight == null || weight < 1 || weight > 64) return 'وزن الخط ${i + 1} يجب أن يكون بين 1 و64.';
      totalWeight += weight;
    }
    if (totalWeight > 64) return 'مجموع الأوزان يجب ألا يتجاوز 64.';
    return null;
  }

  String _quote(String value) => '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

  String _line(String path, Map<String, String> args) =>
      path + (args.isEmpty ? '' : ' ' + args.entries.map((entry) => '${entry.key}=${_quote(entry.value)}').join(' '));

  String _tableName(int index) => 'nova${_id}_w${index + 1}';
  String _connectionMark(int index) => 'novac${_id}_w${index + 1}';
  String _comment(String part) => 'NOVA:PCC:$_id:$part';

  _PccCommand _plan(String path, Map<String, String> args, String description) =>
      _PccCommand(path: path, args: args, cli: _line(path, args), description: description);

  List<_PccCommand> _generateCommands() {
    final built = <_PccCommand>[];
    final weights = _wans.map((wan) => int.parse(wan.weight.text.trim())).toList(growable: false);
    final total = weights.fold<int>(0, (sum, weight) => sum + weight);

    // RouterOS v7 requires a FIB routing table for each policy route mark.
    for (var i = 0; i < _wans.length; i++) {
      built.add(_plan('/routing/table/add', <String, String>{'name': _tableName(i), 'fib': 'yes'},
        'إنشاء جدول التوجيه ${_tableName(i)}'));
    }

    // Dedicated PCC tables get one checked default route each. Main-table routes provide ordered failover.
    for (var i = 0; i < _wans.length; i++) {
      final wan = _wans[i];
      built.add(_plan('/ip/route/add', <String, String>{
        'dst-address': '0.0.0.0/0', 'gateway': wan.gateway.text.trim(),
        'routing-table': _tableName(i), 'check-gateway': 'ping',
        'comment': _comment('route:${i + 1}'),
      }, 'مسار WAN ${i + 1} داخل ${_tableName(i)}'));
      built.add(_plan('/ip/route/add', <String, String>{
        'dst-address': '0.0.0.0/0', 'gateway': wan.gateway.text.trim(),
        'distance': (i + 1).toString(), 'check-gateway': 'ping',
        'comment': _comment('main-route:${i + 1}'),
      }, 'مسار افتراضي احتياطي للخط ${i + 1}'));
    }

    final lan = _lanInterface!;
    built.add(_plan('/ip/firewall/mangle/add', <String, String>{
      'chain': 'prerouting', 'in-interface': lan, 'dst-address-type': 'local',
      'action': 'accept', 'comment': _comment('accept:local-router'),
    }, 'استثناء عناوين الراوتر المحلية'));
    const privateNetworks = <String>['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'];
    for (var i = 0; i < privateNetworks.length; i++) {
      built.add(_plan('/ip/firewall/mangle/add', <String, String>{
        'chain': 'prerouting', 'in-interface': lan, 'dst-address': privateNetworks[i],
        'action': 'accept', 'comment': _comment('accept:private:${i + 1}'),
      }, 'استثناء الشبكة المحلية ${privateNetworks[i]}'));
    }

    // Mark inbound sessions so their replies leave through the same WAN.
    for (var i = 0; i < _wans.length; i++) {
      built.add(_plan('/ip/firewall/mangle/add', <String, String>{
        'chain': 'prerouting', 'in-interface': _wans[i].interfaceName!,
        'connection-mark': 'no-mark', 'action': 'mark-connection',
        'new-connection-mark': _connectionMark(i), 'passthrough': 'yes',
        'comment': _comment('inbound:${i + 1}'),
      }, 'تمييز الاتصالات الواردة من WAN ${i + 1}'));
    }

    // Unequal weights map to multiple remainders of the total PCC denominator.
    var remainder = 0;
    for (var wanIndex = 0; wanIndex < _wans.length; wanIndex++) {
      for (var slot = 0; slot < weights[wanIndex]; slot++) {
        built.add(_plan('/ip/firewall/mangle/add', <String, String>{
          'chain': 'prerouting', 'in-interface': lan, 'connection-mark': 'no-mark',
          'per-connection-classifier': '$_classifier:$total/$remainder',
          'action': 'mark-connection', 'new-connection-mark': _connectionMark(wanIndex),
          'passthrough': 'yes', 'comment': _comment('pcc:${wanIndex + 1}:$remainder'),
        }, 'PCC remainder $remainder/$total إلى WAN ${wanIndex + 1}'));
        remainder++;
      }
    }

    for (var i = 0; i < _wans.length; i++) {
      built.add(_plan('/ip/firewall/mangle/add', <String, String>{
        'chain': 'prerouting', 'in-interface': lan, 'connection-mark': _connectionMark(i),
        'action': 'mark-routing', 'new-routing-mark': _tableName(i), 'passthrough': 'no',
        'comment': _comment('route-mark:${i + 1}'),
      }, 'توجيه جلسات LAN المصنفة نحو WAN ${i + 1}'));
      built.add(_plan('/ip/firewall/mangle/add', <String, String>{
        'chain': 'output', 'connection-mark': _connectionMark(i),
        'action': 'mark-routing', 'new-routing-mark': _tableName(i), 'passthrough': 'no',
        'comment': _comment('output-mark:${i + 1}'),
      }, 'توجيه ردود خدمات الراوتر عبر WAN ${i + 1}'));
    }
    return built;
  }

  Future<void> _preview() async {
    final validation = _validateConfiguration();
    if (validation != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(validation), backgroundColor: const Color(0xFF8C3042)));
      return;
    }
    final client = ref.read(activeRouterClientProvider);
    if (client == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await client.command('/routing/table/print', args: const <String, String>{'.proplist': 'name'});
      final existing = rows.map((row) => row['name']).whereType<String>().toSet();
      final generated = _generateCommands().where((command) {
        return command.path != '/routing/table/add' || !existing.contains(command.args['name']);
      }).toList(growable: false);
      if (!mounted) return;
      setState(() { _commands = generated; _loading = false; _applyStatus = null; });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = 'تعذر تجهيز المعاينة: ${_friendly(error)}'; });
    }
  }

  Future<bool> _confirmApply(int count) async => await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
    backgroundColor: _pccPanel,
    title: const Text('تطبيق قواعد PCC مباشرة؟', style: TextStyle(color: Colors.white)),
    content: Text(
      'سيُرسل $count أمرًا إلى الراوتر الحالي. تُضاف القواعد ولا تحذف أو تستبدل قواعد PCC القديمة. أنشئ نسخة احتياطية وراجع ترتيب Mangle وNAT أولاً. إذا فشل اتصال أو أمر في منتصف التنفيذ فقد تبقى تغييرات جزئية؛ لا يوجد تراجع تلقائي في هذه الشاشة.',
      style: const TextStyle(color: _pccMuted, height: 1.4),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('مراجعة')),
      FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('تطبيق مباشر')),
    ],
  )) ?? false;

  Future<void> _apply() async {
    final commands = _commands;
    final client = ref.read(activeRouterClientProvider);
    if (commands == null || client == null || _applying) return;
    if (_validateConfiguration() != null) {
      setState(() => _commands = null);
      return;
    }
    if (!await _confirmApply(commands.length)) return;
    setState(() { _applying = true; _applyStatus = 'جاري إرسال الأوامر...'; _error = null; });
    var completed = 0;
    try {
      final tableRows = await client.command('/routing/table/print', args: const <String, String>{'.proplist': 'name'});
      final existingTables = tableRows.map((row) => row['name']).whereType<String>().toSet();
      for (final planned in commands) {
        if (planned.path == '/routing/table/add' && existingTables.contains(planned.args['name'])) {
          completed++;
          continue;
        }
        await client.command(planned.path, args: planned.args);
        if (planned.path == '/routing/table/add' && planned.args['name'] != null) existingTables.add(planned.args['name']!);
        completed++;
        if (mounted && completed % 5 == 0) setState(() => _applyStatus = 'تم تنفيذ $completed من ${commands.length} أمرًا...');
      }
      if (mounted) {
        setState(() => _applyStatus = 'اكتمل إرسال $completed أمرًا. راجع Routes وMangle واختبر اتصال المشتركين.');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('انتهى إرسال أوامر PCC. تحقق من حركة المرور والـ routes فوراً.'), backgroundColor: Color(0xFF176D58)));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _applyStatus = 'توقف بعد $completed من ${commands.length}. قد توجد قواعد جزئية تحمل التعليق NOVA:PCC:$_id.');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('توقف التطبيق عند الأمر ${completed + 1}: ${_friendly(error)}'), backgroundColor: const Color(0xFF8C3042)));
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Widget _panel(String title, Widget child) => Container(
    width: double.infinity, margin: const EdgeInsets.only(bottom: 11), padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(color: _pccPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(.06))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12), child,
    ]),
  );

  InputDecoration _decoration(String label, {String? hint}) => InputDecoration(labelText: label, hintText: hint);

  Widget _wanCard(int index) {
    final wan = _wans[index];
    final current = _interfaces.contains(wan.interfaceName) ? wan.interfaceName : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 9), padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white.withOpacity(.05))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 30, height: 30, decoration: BoxDecoration(color: _pccAccent.withOpacity(.16), borderRadius: BorderRadius.circular(9)), child: Center(child: Text('${index + 1}', style: const TextStyle(color: _pccAccent, fontWeight: FontWeight.w900)))),
          const SizedBox(width: 9), const Expanded(child: Text('WAN Uplink', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
          const Text('Weight', style: TextStyle(color: _pccMuted, fontSize: 11)), const SizedBox(width: 7),
          SizedBox(width: 54, child: TextField(controller: wan.weight, keyboardType: TextInputType.number, onChanged: (_) => _invalidate(), style: const TextStyle(color: Colors.white, fontFamily: 'monospace'), decoration: const InputDecoration(isDense: true, hintText: '1'))),
        ]),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: current, dropdownColor: _pccPanel, style: const TextStyle(color: Colors.white),
          decoration: _decoration('Interface'),
          items: _interfaces.map((name) => DropdownMenuItem<String>(value: name, child: Text(name, overflow: TextOverflow.ellipsis))).toList(),
          onChanged: _interfaces.isEmpty ? null : (value) => setState(() { wan.interfaceName = value; _commands = null; _applyStatus = null; }),
        ),
        const SizedBox(height: 8),
        TextField(controller: wan.gateway, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => _invalidate(), style: const TextStyle(color: Colors.white, fontFamily: 'monospace'), decoration: _decoration('Gateway IP', hint: 'مثال: 192.168.1.1')),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(activeRouterClientProvider);
    if (client == null) return const Scaffold(backgroundColor: _pccBg, body: Center(child: Text('اتصل بالراوتر أولاً.', style: TextStyle(color: Colors.white))));
    final commands = _commands;
    return Scaffold(
      backgroundColor: _pccBg,
      appBar: AppBar(
        backgroundColor: _pccBg, foregroundColor: Colors.white, title: const Text('PCC Load Balancing Wizard'),
        actions: [IconButton(onPressed: _loading || _applying ? null : _loadInterfaces, icon: const Icon(Icons.refresh_rounded))],
      ),
      body: _loading ? const Center(child: CircularProgressIndicator(color: _pccAccent)) : ListView(padding: const EdgeInsets.all(12), children: [
        if (_error != null) Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: const Color(0xFF3A1721), borderRadius: BorderRadius.circular(10)), child: Text(_error!, style: const TextStyle(color: _pccRed, fontSize: 12))),
        _panel('1. مخطط الخطوط', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DropdownButtonFormField<int>(
            value: _wanCount, dropdownColor: _pccPanel, style: const TextStyle(color: Colors.white), decoration: _decoration('عدد خطوط WAN'),
            items: <int>[2, 3, 4, 5, 6].map((value) => DropdownMenuItem<int>(value: value, child: Text('$value خطوط'))).toList(),
            onChanged: _applying ? null : (value) { if (value != null) _changeWanCount(value); },
          ),
          const SizedBox(height: 10), for (var i = 0; i < _wans.length; i++) _wanCard(i),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            value: _interfaces.contains(_lanInterface) ? _lanInterface : null,
            dropdownColor: _pccPanel, style: const TextStyle(color: Colors.white), decoration: _decoration('LAN / Bridge Interface'),
            items: _interfaces.map((name) => DropdownMenuItem<String>(value: name, child: Text(name, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: _applying ? null : (value) => setState(() { _lanInterface = value; _commands = null; _applyStatus = null; }),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: _classifier, dropdownColor: _pccPanel, style: const TextStyle(color: Colors.white), decoration: _decoration('PCC Classifier'),
            items: const [
              DropdownMenuItem(value: 'both-addresses-and-ports', child: Text('both-addresses-and-ports')),
              DropdownMenuItem(value: 'both-addresses', child: Text('both-addresses')),
              DropdownMenuItem(value: 'src-address', child: Text('src-address (حسب العميل)')),
            ],
            onChanged: _applying ? null : (value) => setState(() { _classifier = value ?? _classifier; _commands = null; _applyStatus = null; }),
          ),
          const SizedBox(height: 9),
          const Text('الأوزان غير المتساوية تتحول إلى PCC remainder موزع على مجموع الأوزان؛ مجموع الأوزان المسموح 64 كحد أقصى.', style: TextStyle(color: _pccMuted, fontSize: 11, height: 1.35)),
        ])),
        _panel('2. معاينة وتطبيق القواعد', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('سيُنشئ المعالج Routing Tables ومسارات افتراضية بفحص check-gateway=ping وقواعد mangle لاستثناء الشبكات الخاصة ووضع علامات الاتصالات والتوجيه.', style: TextStyle(color: _pccMuted, fontSize: 12, height: 1.45)),
          const SizedBox(height: 10),
          FilledButton.icon(onPressed: _applying ? null : _preview, icon: const Icon(Icons.preview_outlined), label: const Text('معاينة قواعد الدمج')),
          if (commands != null) ...[
            const SizedBox(height: 10),
            Text('${commands.length} أمرًا جاهزًا • ID $_id', style: const TextStyle(color: _pccGreen, fontSize: 11, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Container(width: double.infinity, padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: const Color(0xFF05080D), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFF253246))),
              child: SelectableText(commands.map((command) => command.cli).join('\n'), style: const TextStyle(color: Color(0xFFB7F5D9), fontFamily: 'monospace', fontSize: 10, height: 1.5))),
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8C3042), foregroundColor: Colors.white),
              onPressed: _applying ? null : _apply,
              icon: _applying ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.rocket_launch_outlined),
              label: Text(_applying ? 'جارٍ التطبيق...' : 'Generate & Apply PCC'),
            ),
          ],
          if (_applyStatus != null) ...[
            const SizedBox(height: 10),
            SelectableText(_applyStatus!, style: TextStyle(color: _applyStatus!.startsWith('توقف') ? _pccRed : _pccMuted, fontSize: 11, height: 1.4)),
          ],
        ])),
        _panel('تنبيهات تشغيلية', const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('• أنشئ نسخة احتياطية من الراوتر قبل التطبيق.', style: TextStyle(color: _pccMuted, fontSize: 11, height: 1.6)),
          Text('• القواعد الجديدة تضاف في آخر Mangle؛ راجع ترتيب القواعد القديمة حتى لا تسبقها قواعد PCC أو mark-routing متعارضة.', style: TextStyle(color: _pccMuted, fontSize: 11, height: 1.6)),
          Text('• Gateway IP يجب أن يكون قابلًا للوصول من واجهة WAN المختارة.', style: TextStyle(color: _pccMuted, fontSize: 11, height: 1.6)),
          Text('• مسارات جدول كل WAN مستقلة، والمسارات الرئيسية تضاف بترتيب distance لتوفير failover.', style: TextStyle(color: _pccMuted, fontSize: 11, height: 1.6)),
        ])),
      ]),
    );
  }
}

class _WanForm {
  String? interfaceName;
  final TextEditingController gateway = TextEditingController();
  final TextEditingController weight = TextEditingController(text: '1');
  void dispose() { gateway.dispose(); weight.dispose(); }
}

class _PccCommand {
  const _PccCommand({required this.path, required this.args, required this.cli, required this.description});
  final String path;
  final Map<String, String> args;
  final String cli;
  final String description;
}
