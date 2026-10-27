import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/router_providers.dart';
import '../../core/storage/router_storage_service.dart';
import 'app_security_service.dart';

const Color _settingsBg = Color(0xFF080B12);
const Color _settingsPanel = Color(0xFF111722);
const Color _settingsMuted = Color(0xFF8D9AB0);
const Color _settingsAccent = Color(0xFF8B7CFF);
const Color _settingsGreen = Color(0xFF43D9A3);
const Color _settingsRed = Color(0xFFFF657A);

class AppSettingsScreen extends ConsumerStatefulWidget {
  const AppSettingsScreen({super.key});
  @override
  ConsumerState<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends ConsumerState<AppSettingsScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _pinEnabled = false;
  int _refreshInterval = 1;
  int _routerCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        AppSecurityService.isPinEnabled(),
        AppSecurityService.getRefreshInterval(),
        ref.read(routerStorageServiceProvider).loadRouters(),
      ]);
      if (!mounted) return;
      setState(() {
        _pinEnabled = results[0] as bool;
        _refreshInterval = results[1] as int;
        _routerCount = (results[2] as List<SavedRouter>).length;
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _loading = false);
        _message('تعذر تحميل الإعدادات: $error', isError: true);
      }
    }
  }

  void _message(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: isError ? const Color(0xFF8C3042) : const Color(0xFF176D58),
    ));
  }

  Future<String?> _askSecret({
    required String title,
    required String label,
    bool pin = false,
  }) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
      backgroundColor: _settingsPanel,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      content: SizedBox(width: 360, child: Form(key: formKey, child: TextFormField(
        controller: controller,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: pin ? TextInputType.number : TextInputType.visiblePassword,
        maxLength: pin ? 8 : null,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          final secret = value ?? '';
          if (pin && !RegExp(r'^\d{4,8}$').hasMatch(secret)) return 'أدخل 4 إلى 8 أرقام.';
          if (!pin && secret.length < 8) return 'استخدم 8 أحرف على الأقل.';
          return null;
        },
      ))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
        FilledButton(onPressed: () {
          if (formKey.currentState?.validate() != true) return;
          Navigator.pop(dialogContext, controller.text);
        }, child: const Text('متابعة')),
      ],
    ));
    controller.dispose();
    return result;
  }

  Future<bool> _askConfirmPin(String pin) async {
    final confirm = await _askSecret(title: 'تأكيد رمز PIN', label: 'أعد إدخال الرمز', pin: true);
    return confirm != null && confirm == pin;
  }

  Future<void> _setPin() async {
    final pin = await _askSecret(title: 'تفعيل قفل التطبيق', label: 'اختر PIN من 4 إلى 8 أرقام', pin: true);
    if (pin == null) return;
    if (!await _askConfirmPin(pin)) {
      _message('رمزا PIN غير متطابقين.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await AppSecurityService.setPin(pin);
      if (mounted) setState(() => _pinEnabled = true);
      _message('تم تفعيل قفل التطبيق. سيُطلب PIN عند فتح التطبيق.');
    } catch (error) {
      _message('تعذر تفعيل القفل: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePin() async {
    final current = await _askSecret(title: 'التحقق من PIN الحالي', label: 'PIN الحالي', pin: true);
    if (current == null) return;
    if (!await AppSecurityService.verifyPin(current)) {
      _message('رمز PIN الحالي غير صحيح.', isError: true);
      return;
    }
    final next = await _askSecret(title: 'تغيير PIN', label: 'PIN جديد من 4 إلى 8 أرقام', pin: true);
    if (next == null) return;
    if (!await _askConfirmPin(next)) {
      _message('رمزا PIN غير متطابقين.', isError: true);
      return;
    }
    try {
      await AppSecurityService.setPin(next);
      _message('تم تغيير رمز PIN.');
    } catch (error) {
      _message('تعذر تغيير الرمز: $error', isError: true);
    }
  }

  Future<void> _disablePin() async {
    final current = await _askSecret(title: 'إيقاف قفل التطبيق', label: 'أدخل PIN الحالي', pin: true);
    if (current == null) return;
    if (!await AppSecurityService.verifyPin(current)) {
      _message('رمز PIN الحالي غير صحيح.', isError: true);
      return;
    }
    await AppSecurityService.clearPin();
    if (mounted) setState(() => _pinEnabled = false);
    _message('تم إيقاف قفل التطبيق.');
  }

  Future<void> _updateInterval(int? seconds) async {
    if (seconds == null || _busy) return;
    setState(() => _busy = true);
    try {
      await AppSecurityService.setRefreshInterval(seconds);
      if (mounted) setState(() => _refreshInterval = seconds);
      _message('تم حفظ معدل التحديث: كل $seconds ثانية.');
    } catch (error) {
      _message('تعذر حفظ معدل التحديث: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportBackup() async {
    if (_busy) return;
    final password = await _askSecret(title: 'تشفير نسخة الراوترات', label: 'كلمة مرور النسخة (8 أحرف على الأقل)');
    if (password == null) return;
    final confirm = await _askSecret(title: 'تأكيد كلمة مرور النسخة', label: 'أعد كتابة كلمة المرور');
    if (confirm == null) return;
    if (password != confirm) {
      _message('كلمتا المرور غير متطابقتين.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final routers = await ref.read(routerStorageServiceProvider).loadRouters();
      final encrypted = await AppSecurityService.encryptRouterBackup(routers, password);
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'حفظ نسخة Nova المشفرة',
        fileName: 'nova-router-backup.json',
        bytes: Uint8List.fromList(encrypted),
      );
      if (savedPath != null) {
        if (mounted) setState(() => _routerCount = routers.length);
        _message('تم تصدير نسخة مشفرة تضم ${routers.length} راوتر.');
      }
    } catch (error) {
      _message('فشل تصدير النسخة: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<_ImportMode?> _chooseImportMode(int count) => showDialog<_ImportMode>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: _settingsPanel,
      title: const Text('استيراد الراوترات', style: TextStyle(color: Colors.white)),
      content: Text('تم فك التشفير بنجاح: $count راوتر. اختر طريقة الاستيراد.', style: const TextStyle(color: _settingsMuted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('إلغاء')),
        OutlinedButton(onPressed: () => Navigator.pop(dialogContext, _ImportMode.merge), child: const Text('دمج مع الحالي')),
        FilledButton(onPressed: () => Navigator.pop(dialogContext, _ImportMode.replace), child: const Text('استبدال الكل')),
      ],
    ),
  );

  Future<void> _importBackup() async {
    if (_busy) return;
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['json'],
        allowMultiple: false,
        withData: true,
      );
      if (selection == null || selection.files.isEmpty) return;
      final file = selection.files.first;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) bytes = await File(file.path!).readAsBytes();
      if (bytes == null) {
        _message('تعذر قراءة الملف المحدد.', isError: true);
        return;
      }
      final password = await _askSecret(title: 'فك تشفير النسخة', label: 'كلمة مرور النسخة');
      if (password == null) return;
      setState(() => _busy = true);
      final restored = await AppSecurityService.decryptRouterBackup(bytes, password);
      final mode = await _chooseImportMode(restored.length);
      if (mode == null) return;
      final storage = ref.read(routerStorageServiceProvider);
      List<SavedRouter> finalRouters;
      if (mode == _ImportMode.replace) {
        finalRouters = restored;
      } else {
        final current = await storage.loadRouters();
        final byId = <String, SavedRouter>{for (final router in current) router.id: router};
        for (final router in restored) {
          byId[router.id] = router;
        }
        finalRouters = byId.values.toList(growable: false);
      }
      await storage.replaceAll(finalRouters);
      await ref.read(savedRoutersProvider.notifier).reload();
      if (mounted) setState(() => _routerCount = finalRouters.length);
      _message('اكتمل الاستيراد. إجمالي الراوترات المحفوظة: ${finalRouters.length}.');
    } catch (error) {
      _message('فشل استيراد النسخة: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _panel({required String title, required Widget child, Widget? action}) => Container(
    width: double.infinity, margin: const EdgeInsets.only(bottom: 13), padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: _settingsPanel, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white.withOpacity(.06))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800))), if (action != null) action]),
      const SizedBox(height: 10), child,
    ]),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _settingsBg,
      appBar: AppBar(backgroundColor: _settingsBg, foregroundColor: Colors.white, title: const Text('إعدادات التطبيق والأمان')),
      body: _loading
        ? const Center(child: CircularProgressIndicator(color: _settingsAccent))
        : ListView(padding: const EdgeInsets.all(14), children: [
          _panel(title: 'قفل التطبيق App Security Lock', child: Column(children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _pinEnabled,
              activeThumbColor: _settingsGreen,
              title: const Text('طلب PIN عند فتح التطبيق', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              subtitle: const Text('الرمز يُخزّن كقيمة مشتقة في التخزين الآمن، ولا يُحفظ كنص صريح.', style: TextStyle(color: _settingsMuted, fontSize: 11)),
              onChanged: _busy ? null : (enabled) => enabled ? _setPin() : _disablePin(),
            ),
            if (_pinEnabled) Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(onPressed: _busy ? null : _changePin, icon: const Icon(Icons.password_rounded), label: const Text('تغيير رمز PIN'))),
          ])),
          _panel(title: 'تصدير واستيراد الراوترات • Encrypted Backup', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.router_outlined, color: _settingsAccent),
              const SizedBox(width: 8),
              Expanded(child: Text('الراوترات المحفوظة: $_routerCount', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
            ]),
            const SizedBox(height: 8),
            const Text('تُشفّر البيانات بخوارزمية AES-256-GCM مع اشتقاق مفتاح من كلمة المرور. الملف لا يحتوي على كلمات مرور الراوترات كنص مقروء.', style: TextStyle(color: _settingsMuted, fontSize: 11, height: 1.45)),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: FilledButton.tonalIcon(onPressed: _busy ? null : _exportBackup, icon: const Icon(Icons.file_download_outlined), label: const Text('تصدير مشفّر'))),
              const SizedBox(width: 9),
              Expanded(child: OutlinedButton.icon(onPressed: _busy ? null : _importBackup, icon: const Icon(Icons.file_upload_outlined), label: const Text('استيراد ملف'))),
            ]),
            const SizedBox(height: 8),
            const Text('احتفظ بكلمة مرور النسخة خارج الهاتف. لا يمكن استرجاع البيانات إذا فُقدت كلمة المرور.', style: TextStyle(color: _settingsRed, fontSize: 11, height: 1.4)),
          ])),
          _panel(title: 'معدل تحديث العدادات', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('تحديث موارد Dashboard كل $_refreshInterval ثانية', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            SegmentedButton<int>(
              segments: const <ButtonSegment<int>>[
                ButtonSegment<int>(value: 1, label: Text('1 ثانية')),
                ButtonSegment<int>(value: 2, label: Text('2 ثانية')),
                ButtonSegment<int>(value: 5, label: Text('5 ثوانٍ')),
              ],
              selected: <int>{_refreshInterval},
              onSelectionChanged: _busy ? null : (selection) => _updateInterval(selection.first),
            ),
            const SizedBox(height: 9),
            const Text('المعدل الأكبر يقلل طلبات polling لموارد الراوتر. تدفقات أدوات الفحص الحية تستمر وفق بروتوكولها حتى توقفها.', style: TextStyle(color: _settingsMuted, fontSize: 11, height: 1.45)),
          ])),
          if (_busy) const LinearProgressIndicator(color: _settingsAccent),
        ]),
    );
  }
}

enum _ImportMode { merge, replace }
