import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/router_providers.dart';

const _bg = Color(0xFF080B12), _panel = Color(0xFF111722), _muted = Color(0xFF8D9AB0), _accent = Color(0xFF8B7CFF);
class HotspotTemplateInstallerScreen extends ConsumerStatefulWidget {
  const HotspotTemplateInstallerScreen({super.key});
  @override
  ConsumerState<HotspotTemplateInstallerScreen> createState() => _HotspotTemplateInstallerScreenState();
}
class _HotspotTemplateInstallerScreenState extends ConsumerState<HotspotTemplateInstallerScreen> {
  final _form = GlobalKey<FormState>();
  final _network = TextEditingController(text: 'NOVA WiFi');
  final _phone = TextEditingController();
  final _prices = TextEditingController(text: 'ساعة — 1,000 ل.س\nيوم — 3,000 ل.س\nأسبوع — 15,000 ل.س');
  Color _color = _accent;
  bool _busy = false;
  String _status = '';
  String _html = '';
  @override
  void dispose() { _network.dispose(); _phone.dispose(); _prices.dispose(); super.dispose(); }
  String _esc(String s) => s.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&#39;');
  String _generate() {
    final name = _esc(_network.text.trim()), phone = _esc(_phone.text.trim());
    final priceRows = _prices.text.split('\n').where((s)=>s.trim().isNotEmpty).map((s)=>'<li>${_esc(s.trim())}</li>').join();
    final color = '#${_color.value.toRadixString(16).substring(2)}';
    final contact = phone.isEmpty ? 'خدمة الإنترنت اللاسلكي' : 'للتواصل والدعم: <a href="tel:$phone">$phone</a>';
    return '''<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="$color"><title>$name</title>
<style>:root{--a:$color}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;place-items:center;padding:20px;background:radial-gradient(ellipse at top,var(--a)33,transparent 58%),#080b12;color:#fff;font-family:system-ui,sans-serif}.card{width:min(100%,420px);padding:26px;border:1px solid #ffffff22;border-radius:25px;background:#111722ee;box-shadow:0 24px 80px #0008}.logo{width:55px;height:55px;border-radius:17px;display:grid;place-items:center;background:var(--a);font-size:25px;font-weight:900}h1{font-size:25px;margin:18px 0 8px}p,footer{color:#aab5c8;font-size:13px;line-height:1.7}label{display:block;font-size:12px;margin:14px 0 7px}input{width:100%;padding:14px;border-radius:12px;border:1px solid #ffffff25;background:#080b12;color:white;font-size:15px}button{width:100%;border:0;border-radius:12px;padding:14px;margin-top:12px;background:var(--a);color:white;font-weight:800;font-size:14px;cursor:pointer}.secondary{background:#ffffff10;border:1px solid #ffffff25}.prices{padding:14px 18px;border-radius:14px;background:#080b12;margin-top:18px}.prices h2{font-size:13px}.prices li{padding:6px 0;font-size:13px}footer{text-align:center;margin-top:18px}a{color:white}</style></head><body><main class="card"><div class="logo">N</div><h1>$name</h1><p>مرحباً بك! أدخل بيانات بطاقة الإنترنت للاتصال بالشبكة.</p>
<form name="login" action="\$(link-login-only)" method="post" onsubmit="saveCard()"><input type="hidden" name="dst" value="\$(link-orig)"><input type="hidden" name="popup" value="true"><label for="username">اسم المستخدم / رقم الكرت</label><input id="username" name="username" autocomplete="username" required placeholder="أدخل رمز البطاقة"><label for="password">كلمة المرور</label><input id="password" name="password" type="password" autocomplete="current-password" placeholder="إذا كانت مطلوبة"><button type="submit">تسجيل الدخول</button></form>
<section class="prices"><h2>الباقات والأسعار</h2><ul>$priceRows</ul></section><button class="secondary" type="button" onclick="document.getElementById('qr').click()">مسح QR Code</button><input id="qr" type="file" accept="image/*" capture="environment" hidden onchange="readQrFile(this)"><button class="secondary" type="button" onclick="saveCard()">حفظ بيانات الكرت على هذا الجهاز</button><footer>$contact</footer></main>
<script>function saveCard(){try{localStorage.setItem('nova_hotspot_user',document.getElementById('username').value||'');localStorage.setItem('nova_hotspot_pass',document.getElementById('password').value||'')}catch(e){}}window.addEventListener('DOMContentLoaded',()=>{try{document.getElementById('username').value=localStorage.getItem('nova_hotspot_user')||'';document.getElementById('password').value=localStorage.getItem('nova_hotspot_pass')||''}catch(e){}});function readQrFile(i){if(i.files&&i.files[0])alert('تم اختيار صورة QR؛ يلزم قارئ QR مدمج لفك الترميز.');}</script></body></html>''';
  }
  Future<void> _upload() async {
    if (!_form.currentState!.validate()) return;
    final client = ref.read(activeRouterClientProvider);
    if (client == null) { setState(()=>_status='اتصل براوتر أولاً.'); return; }
    if (client.useRestApi) { setState(()=>_status='الاتصال الحالي REST للقراءة فقط. استخدم اتصال RouterOS API socket لرفع الملفات.'); return; }
    setState(()=>_busy=true);
    try {
      final html = _generate();
      if (mounted) setState(() => _html = html);
      final rows = await client.command('/file/print', args: const {'.proplist':'.id,name'});
      final target = rows.where((r)=>(r['name']??'').replaceAll('\\','/')=='hotspot/login.html');
      if (target.isNotEmpty && (target.first['.id']??'').isNotEmpty) {
        await client.command('/file/set', args: {'.id':target.first['.id']!,'contents':html});
      } else {
        await client.command('/file/add', args: {'name':'hotspot/login.html','contents':html});
      }
      if (mounted) setState(()=>_status='أُرسل طلب الرفع. تحقق من Files على الراوتر ومن صلاحية ملف hotspot/login.html ثم اختبره على عميل تجريبي.');
    } catch(e) { if(mounted) setState(()=>_status='فشل الرفع: $e'); }
    finally { if(mounted) setState(()=>_busy=false); }
  }
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor:_bg,body:ListView(padding:const EdgeInsets.all(16),children:[
    Container(padding:const EdgeInsets.all(18),decoration:BoxDecoration(borderRadius:BorderRadius.circular(22),gradient:const LinearGradient(colors:[Color(0xFF292647),_panel]),border:Border.all(color:_accent.withOpacity(.3))),child:const Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(Icons.web_asset_rounded,color:_accent,size:34),SizedBox(height:12),Text('مولّد صفحة الهوتسبوت',style:TextStyle(fontSize:20,fontWeight:FontWeight.w900)),SizedBox(height:6),Text('صفحة عربية متجاوبة مع حفظ الكرت محلياً ورفع إلى hotspot/login.html.',style:TextStyle(color:_muted,height:1.5))])),
    const SizedBox(height:16),Form(key:_form,child:Column(children:[
      TextFormField(controller:_network,decoration:const InputDecoration(labelText:'اسم الشبكة'),validator:(v)=>v==null||v.trim().isEmpty?'اسم الشبكة مطلوب':null),
      const SizedBox(height:12),TextFormField(controller:_phone,keyboardType:TextInputType.phone,decoration:const InputDecoration(labelText:'رقم الهاتف للتواصل')),
      const SizedBox(height:12),TextFormField(controller:_prices,maxLines:4,decoration:const InputDecoration(labelText:'جدول أسعار الباقات (كل باقة بسطر)')),
      const SizedBox(height:14),const Align(alignment:Alignment.centerRight,child:Text('لون الثيم',style:TextStyle(color:_muted))),const SizedBox(height:9),
      Wrap(spacing:10,children:const [Color(0xFF8B7CFF),Color(0xFF00A8A8),Color(0xFF2878FF),Color(0xFFE09B35),Color(0xFFE65378),Color(0xFF25885B)].map((c)=>c).toList().map((c)=>Builder(builder:(context)=>InkWell(onTap:()=>setState(()=>_color=c),child:Container(width:38,height:38,decoration:BoxDecoration(color:c,shape:BoxShape.circle,border:Border.all(color:_color==c?Colors.white:Colors.transparent,width:3)),child:_color==c?const Icon(Icons.check,color:Colors.white,size:18):null)))).toList()),
      const SizedBox(height:18),SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:_busy?null:_upload,icon:_busy?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.cloud_upload_rounded),label:Text(_busy?'جارٍ الرفع...':'توليد ورفع الصفحة للراوتر'))),
    ])),
    if(_status.isNotEmpty)Padding(padding:const EdgeInsets.only(top:14),child:Text(_status,style:const TextStyle(color:Colors.white,height:1.5))),
    if(_html.isNotEmpty)TextButton.icon(onPressed:()=>Clipboard.setData(ClipboardData(text:_html)),icon:const Icon(Icons.copy),label:const Text('نسخ كود الصفحة')),
    const SizedBox(height:12),const Text('تنبيه: زر QR يفتح اختيار صورة فقط؛ فك ترميز QR يحتاج مكتبة قارئ مضمّنة. اختبر الصفحة على عميل تجريبي قبل اعتمادها.',style:TextStyle(color:_muted,fontSize:12,height:1.5))
  ]));
}