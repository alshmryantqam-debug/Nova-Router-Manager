import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/router_providers.dart';
import '../../core/storage/router_storage_service.dart';
import 'cgnat_bypass_service.dart';

const _bg = Color(0xFF080B12), _panel = Color(0xFF111722), _accent = Color(0xFF8B7CFF);
const _muted = Color(0xFF8D9AB0), _green = Color(0xFF43D9A3), _red = Color(0xFFFF657A);

class CgnatBypassScreen extends ConsumerStatefulWidget {
  const CgnatBypassScreen({super.key});
  @override
  ConsumerState<CgnatBypassScreen> createState() => _CgnatBypassScreenState();
}
class _CgnatBypassScreenState extends ConsumerState<CgnatBypassScreen> {
  final _network = TextEditingController(), _server = TextEditingController(),
      _user = TextEditingController(), _password = TextEditingController(),
      _ipsec = TextEditingController(), _port = TextEditingController();
  CgnatBypassService? _service;
  ZeroTierTunnelStatus? _zt;
  List<ReverseVpnResult> _tunnels = [];
  String _type = 'SSTP';
  bool _busy = false, _loading = true, _hidePassword = true;
  String? _error;
  Timer? _timer;

  @override void initState() {
    super.initState();
    final c = ref.read(activeRouterClientProvider);
    if (c == null) { _loading = false; _error = 'اتصل بالراوتر أولاً.'; }
    else {
      _service = CgnatBypassService(c);
      unawaited(_refresh());
      _timer = Timer.periodic(const Duration(seconds: 8), (_) { if (!_busy) unawaited(_refresh(silent: true)); });
    }
  }
  @override void dispose() {
    _timer?.cancel();
    for (final c in [_network, _server, _user, _password, _ipsec, _port]) { c.dispose(); }
    super.dispose();
  }
  String _err(Object e) => e.toString().replaceFirst('RouterOsException: ', '').replaceFirst('Bad state: ', '');
  void _toast(String value, {bool bad = false}) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value),
      backgroundColor: bad ? _red : const Color(0xFF1A443C), behavior: SnackBarBehavior.floating));
  }
  Future<void> _refresh({bool silent = false}) async {
    final s = _service; if (s == null) return;
    if (!silent && mounted) setState(() => _loading = true);
    try {
      ZeroTierTunnelStatus? z;
      final id = _network.text.trim();
      if (id.length == 16 && RegExp(r'^[0-9a-fA-F]{16}').hasMatch(id)) {
        final rows = await s.listZeroTierInterfaces();
        final found = rows.where((r) => (r['network'] ?? '').toLowerCase() == id.toLowerCase());
        if (found.isNotEmpty) z = await s.pollZeroTierStatus(networkId: id.toLowerCase(), interfaceName: found.first['name']);
      }
      final tunnels = await s.listReverseVpns();
      if (mounted) setState(() { if (z != null) _zt = z; _tunnels = tunnels; _loading = false; if (!silent) _error = null; });
    } catch (e) { if (mounted) setState(() { _loading = false; if (!silent) _error = _err(e); }); }
  }
  Future<void> _connectZt() async {
    final s = _service; final id = _network.text.trim();
    if (s == null || _busy) return;
    if (id.length != 16 || !RegExp(r'^[0-9a-fA-F]{16}').hasMatch(id)) { _toast('Network ID يجب أن يتكون من 16 خانة hexadecimal.', bad: true); return; }
    setState(() { _busy = true; _error = null; });
    try {
      final r = await s.connectZeroTier(id);
      if (mounted) setState(() => _zt = r);
      _toast('ZeroTier: ' + r.status + ' • IP: ' + (r.ipAddress ?? 'لم يخصص بعد'));
      await _refresh(silent: true);
    } catch (e) { if (mounted) setState(() => _error = _err(e)); _toast(_err(e), bad: true); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _saveZt() async {
    final z = _zt; final active = ref.read(activeRouterDetailsProvider);
    if (z?.ipAddress == null || active == null || _busy) return;
    setState(() => _busy = true);
    try {
      final ip = z!.ipAddress!;
      await ref.read(savedRoutersProvider.notifier).saveRouter(SavedRouter(
        id: 'nova-zt-' + active.id + '-' + ip.replaceAll('.', '-'),
        name: active.name + ' • ZeroTier', host: ip, port: active.port,
        username: active.username, password: active.password, useSsl: active.useSsl, useRestApi: active.useRestApi));
      _toast('حُفظ عنوان ZeroTier ' + ip + '. اتصل عبر ZeroTier أولاً.');
    } catch (e) { _toast(_err(e), bad: true); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _createReverse() async {
    final s = _service; if (s == null || _busy) return;
    if (_server.text.trim().isEmpty || _user.text.trim().isEmpty || _password.text.isEmpty) { _toast('أدخل السيرفر واسم المستخدم وكلمة المرور.', bad: true); return; }
    final p = int.tryParse(_port.text.trim());
    if (_port.text.trim().isNotEmpty && (p == null || p < 1 || p > 65535)) { _toast('منفذ VPN غير صالح.', bad: true); return; }
    setState(() { _busy = true; _error = null; });
    try {
      final r = await s.createReverseVpn(type: _type, server: _server.text.trim(), username: _user.text.trim(),
        password: _password.text, ipsecSecret: _ipsec.text.trim().isEmpty ? null : _ipsec.text, port: p);
      await _refresh(silent: true);
      _toast('تم إنشاء ' + r.type + ' • الحالة ' + r.state + '.');
    } catch (e) { if (mounted) setState(() => _error = _err(e)); _toast(_err(e), bad: true); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  Future<void> _remove(ReverseVpnResult t) async {
    final s = _service; if (s == null || _busy) return;
    final yes = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: _panel, title: const Text('حذف نفق VPN؟'),
      content: Text('سيُحذف ' + t.name + ' وجدول الاستعادة.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف'))])) ?? false;
    if (!yes) return;
    setState(() => _busy = true);
    try { await s.removeReverseVpn(t); await _refresh(silent: true); _toast('تم حذف النفق.'); }
    catch (e) { _toast(_err(e), bad: true); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  InputDecoration _dec(String label, {String? hint}) => InputDecoration(labelText: label, hintText: hint,
    labelStyle: const TextStyle(color: _muted, fontSize: 12), filled: true, fillColor: const Color(0xFF0B1019),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)));
  Widget _card(String title, Widget child) => Container(margin: const EdgeInsets.only(bottom: 12), padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(17), border: Border.all(color: Colors.white.withOpacity(.07))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
      const SizedBox(height: 12), child]));

  @override Widget build(BuildContext context) {
    if (_service == null || ref.watch(activeRouterClientProvider) == null) return Scaffold(backgroundColor: _bg,
      appBar: AppBar(title: const Text('تجاوز CGNAT')), body: const Center(child: Text('اتصل بالراوتر أولاً.', style: TextStyle(color: Colors.white70))));
    return DefaultTabController(length: 2, child: Scaffold(backgroundColor: _bg,
      appBar: AppBar(backgroundColor: _bg, foregroundColor: Colors.white, title: const Text('أنفاق CGNAT وStarlink'),
        actions: [IconButton(onPressed: _busy ? null : () => _refresh(), icon: const Icon(Icons.refresh, color: _accent))],
        bottom: const TabBar(indicatorColor: _accent, tabs: [Tab(icon: Icon(Icons.hub_rounded), text: 'ZeroTier One'), Tab(icon: Icon(Icons.vpn_lock_rounded), text: 'Reverse VPN')])),
      body: Column(children: [
        if (_error != null) Container(width: double.infinity, margin: const EdgeInsets.all(10), padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: _red.withOpacity(.1), border: Border.all(color: _red.withOpacity(.4)), borderRadius: BorderRadius.circular(10)),
          child: Text(_error!, style: const TextStyle(color: _red, fontSize: 12))),
        Expanded(child: _loading ? const Center(child: CircularProgressIndicator(color: _accent)) : TabBarView(children: [_zeroTierTab(), _reverseTab()]))])));
  }
  Widget _zeroTierTab() => ListView(padding: const EdgeInsets.all(13), children: [
    _card('ربط ZeroTier بضغطة زر', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('وصول خارجي خلف CGNAT دون فتح منافذ الإدارة على الإنترنت العام. يلزم تثبيت حزمة ZeroTier المتوافقة واعتماد الراوتر في ZeroTier Central إذا كانت الشبكة خاصة.',
        style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5)),
      const SizedBox(height: 12),
      TextField(controller: _network, textDirection: TextDirection.ltr, autocorrect: false, enableSuggestions: false,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')), LengthLimitingTextInputFormatter(16)],
        decoration: _dec('Network ID (16 خانة)', hint: '8056c2e21c000001')),
      const SizedBox(height: 10), SizedBox(height: 48, child: FilledButton.icon(onPressed: _busy ? null : _connectZt,
        icon: _busy ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.bolt),
        label: Text(_busy ? 'جارٍ إنشاء النفق...' : 'ربط وإنشاء النفق فوراً')))])),
    if (_zt != null) _card('حالة النفق وعنوان IP', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [Expanded(child: Text(_zt!.interfaceName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
        Text(_zt!.status, style: TextStyle(color: _zt!.status.toUpperCase() == 'OK' ? _green : _accent, fontWeight: FontWeight.bold))]),
      const SizedBox(height: 8), SelectableText('Network ID: ' + _zt!.networkId + '\nZeroTier IP: ' + (_zt!.ipAddress ?? 'لم يخصص بعد'),
        style: const TextStyle(color: _green, fontFamily: 'monospace', fontSize: 13, height: 1.7)),
      Text(_zt!.message, style: const TextStyle(color: _muted, fontSize: 11)),
      if (_zt!.ipAddress != null) ...[const SizedBox(height: 10), FilledButton.icon(onPressed: _busy ? null : _saveZt,
        icon: const Icon(Icons.bookmark_add), label: const Text('إضافة هذا الـ IP كاتصال خارجي للراوتر')),
        const Text('يُحفظ اتصال جديد ببيانات الإدارة الحالية. يجب اتصال الهاتف أو الكمبيوتر بشبكة ZeroTier نفسها.',
          style: TextStyle(color: _muted, fontSize: 10, height: 1.5))]])),
    _card('أمان الشبكة', const Text('السماح يقتصر على واجهة ZeroTier ولا يفتح منافذ الإدارة على WAN. اعتمد أعضاء موثوقين فقط؛ لا تضف Forward إلى LAN إلا بعد تقييد الشبكات والخدمات.',
      style: TextStyle(color: Colors.white70, fontSize: 11, height: 1.5))) ]);

  Widget _reverseTab() => ListView(padding: const EdgeInsets.all(13), children: [
    _card('Reverse VPN Client', Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('اتصال صادر من الراوتر إلى خادم VPN خارجي يملك Public IP. أنشئ حساب العميل على الخادم مسبقاً.',
        style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5)),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(value: _type, dropdownColor: _panel, style: const TextStyle(color: Colors.white), decoration: _dec('نوع النفق'),
        items: const [DropdownMenuItem(value:'L2TP',child:Text('L2TP Client')), DropdownMenuItem(value:'SSTP',child:Text('SSTP Client (TLS)')), DropdownMenuItem(value:'OVPN',child:Text('OpenVPN Client'))],
        onChanged: _busy ? null : (v) => setState(() => _type = v ?? 'SSTP')),
      const SizedBox(height: 9), TextField(controller: _server, textDirection: TextDirection.ltr, autocorrect: false, decoration: _dec('عنوان السيرفر أو DNS')),
      const SizedBox(height: 9), TextField(controller: _port, textDirection: TextDirection.ltr, keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: _dec('المنفذ (اختياري)', hint: _type == 'SSTP' ? '443' : _type == 'OVPN' ? '1194' : '1701')),
      const SizedBox(height: 9), TextField(controller: _user, textDirection: TextDirection.ltr, autocorrect: false, decoration: _dec('اسم المستخدم')),
      const SizedBox(height: 9), TextField(controller: _password, textDirection: TextDirection.ltr, obscureText: _hidePassword, autocorrect: false, enableSuggestions: false,
        decoration: _dec('كلمة المرور').copyWith(suffixIcon: IconButton(onPressed: () => setState(() => _hidePassword = !_hidePassword), icon: Icon(_hidePassword ? Icons.visibility : Icons.visibility_off, color: _muted)))),
      if (_type == 'L2TP') ...[const SizedBox(height: 9), TextField(controller: _ipsec, textDirection: TextDirection.ltr, obscureText: true, decoration: _dec('IPsec pre-shared key (اختياري)'))],
      const SizedBox(height: 12), SizedBox(height: 48, child: FilledButton.icon(onPressed: _busy ? null : _createReverse,
        icon: _busy ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync_lock),
        label: Text(_busy ? 'جارٍ إنشاء النفق...' : 'إنشاء نفق عكسي مستمر')))])),
    _card('حالة الأنفاق (' + _tunnels.length.toString() + ')', _tunnels.isEmpty
      ? const Text('لا توجد أنفاق عكسية أنشأها التطبيق.', style: TextStyle(color: Colors.white60, fontSize: 12))
      : Column(children: _tunnels.map((t) => Container(margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(12)),
        child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
          title: Text(t.type + ' • ' + t.name, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          subtitle: Text('الحالة: ' + t.state + '\nRemote IP: ' + (t.remoteAddress ?? '—') + ' • Local IP: ' + (t.localAddress ?? '—'),
            style: const TextStyle(color: Colors.white60, fontSize: 10, height: 1.6)),
          trailing: IconButton(onPressed: _busy ? null : () => _remove(t), icon: const Icon(Icons.delete_outline, color: _red))))).toList())),
    _card('المراقبة والاستعادة', const Text('يضاف Schedule كل دقيقة يفحص Running ويعيد تفعيل الواجهة إذا فصلت. يلزم خادم VPN وحساب صالح. SSTP يتحقق من شهادة الخادم؛ يمكن تزويد L2TP بمفتاح IPsec.',
      style: TextStyle(color: Colors.white70, fontSize: 11, height: 1.5))) ]);
}
