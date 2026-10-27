import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const _bg=Color(0xFF080B12), _panel=Color(0xFF111722), _accent=Color(0xFF8B7CFF), _muted=Color(0xFF8D9AB0), _green=Color(0xFF43D9A3), _red=Color(0xFFFF657A);
class ExternalSecurityPortfwdScreen extends ConsumerStatefulWidget {
 const ExternalSecurityPortfwdScreen({super.key});
 @override ConsumerState<ExternalSecurityPortfwdScreen> createState()=>_ExternalSecurityPortfwdScreenState();
}
class _ExternalSecurityPortfwdScreenState extends ConsumerState<ExternalSecurityPortfwdScreen> {
 RouterOsClient? get client=>ref.read(activeRouterClientProvider);
 List<Map<String,String>> services=[],rules=[];
 bool busy=false,loading=true,knockEnabled=false;
 String? error;
 final p1=TextEditingController(text:'7000'),p2=TextEditingController(text:'8000'),ip=TextEditingController(text:'192.168.88.2'),insidePort=TextEditingController(text:'80'),outsidePort=TextEditingController(text:'18080'),wan=TextEditingController(text:'ether1');
 String protocol='tcp';
 @override void initState(){super.initState();_load();}
 @override void dispose(){for(final c in [p1,p2,ip,insidePort,outsidePort,wan]){c.dispose();}super.dispose();}
 String err(Object e)=>e.toString().replaceFirst('RouterOsException: ','');
 void toast(String s,{bool bad=false}){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s),backgroundColor:bad?_red:const Color(0xFF1A443C)));}
 Future<void> _load() async {
  final c=client;if(c==null){setState(()=>loading=false);return;}
  try {
   final r=await Future.wait([c.command('/ip/service/print'),c.command('/ip/firewall/filter/print',args:const {'.proplist':'.id,chain,action,protocol,dst-port,src-address-list,address-list,address-list-timeout,comment,disabled'})]);
   if(!mounted)return;setState(() { services=r[0].where((x)=>const ['api','api-ssl','winbox','www','ssh'].contains(x['name'])).toList(); rules=r[1].where((x)=>(x['comment']??'').startsWith('NOVA:PORTKNOCK:')).toList(); knockEnabled=r[1].any((x)=>(x['comment']??'')=='NOVA:PORTKNOCK:DROP'&&x['disabled']!='true'&&x['disabled']!='yes'); loading=false; error=null; });
  } catch(e){if(mounted)setState(() { loading=false; error=err(e); });}
 }
 Future<void> _setService(Map<String,String> s,{String? port,String? address,bool? disabled}) async {
  final c=client,id=s['.id']??s['id'];if(c==null||id==null)return;
  setState(()=>busy=true);
  try{final a=<String,String>{'.id':id};if(port!=null)a['port']=port;if(address!=null)a['address']=address;if(disabled!=null)a['disabled']=disabled?'yes':'no';await c.command('/ip/service/set',args:a);toast('تم تحديث '+(s['name']??'الخدمة'));await _load();}
  catch(e){toast(err(e),bad:true);}finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> _edit(Map<String,String> s) async {
  final p=TextEditingController(text:s['port']??''),a=TextEditingController(text:s['address']??'');
  final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(backgroundColor:_panel,title:Text('إعداد '+(s['name']??'')),content:Column(mainAxisSize:MainAxisSize.min,children:[
   TextField(controller:p,keyboardType:TextInputType.number,inputFormatters:[FilteringTextInputFormatter.digitsOnly],decoration:const InputDecoration(labelText:'المنفذ')),
   TextField(controller:a,textDirection:TextDirection.ltr,maxLines:2,decoration:const InputDecoration(labelText:'عناوين IP المسموح بها',hintText:'192.168.88.0/24,10.0.0.5/32'))]),
   actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('حفظ'))]));
  if(ok==true){final n=int.tryParse(p.text);if(n==null||n<1||n>65535||a.text.trim().isEmpty){toast('تحقق من المنفذ والعناوين المسموحة.',bad:true);}else{await _setService(s,port:p.text.trim(),address:a.text.trim());}}p.dispose();a.dispose();
 }
 Future<bool> confirm(String title,String body) async=>await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(backgroundColor:_panel,title:Text(title),content:Text(body),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('متابعة'))]))??false;
 int? port(TextEditingController c){final n=int.tryParse(c.text.trim());return n!=null&&n>0&&n<=65535?n:null;}
 Future<void> _knock() async {
  final c=client;if(c==null||busy)return;
  if(knockEnabled){if(!await confirm('تعطيل القفل؟','ستُعطّل قواعد NOVA:PORTKNOCK؛ قد تعود منافذ الإدارة مكشوفة وفق بقية الفايروول.'))return;setState(()=>busy=true);try{for(final r in rules){final id=r['.id']??r['id'];if(id!=null)await c.command('/ip/firewall/filter/set',args:{'.id':id,'disabled':'yes'});}toast('عُطّلت القواعد ولم تُحذف.');await _load();}catch(e){toast(err(e),bad:true);}finally{if(mounted)setState(()=>busy=false);}return;}
  final a=port(p1),b=port(p2);if(a==null||b==null||a==b){toast('أدخل منفذين مختلفين صالحين.',bad:true);return;}
  if(!await confirm('تفعيل Port Knocking؟','سيقيّد API وWinBox بمصدر Trusted_Admin بعد الطرق بالترتيب. قد تفقد الإدارة إن لم تُجرّب الاتصال من مصدر موثوق.'))return;
  setState(()=>busy=true);
  try{
   final protected=services.where((s)=>const ['api','api-ssl','winbox'].contains(s['name'])).map((s)=>s['port']).whereType<String>().where((s)=>int.tryParse(s)!=null).toSet().toList();if(!protected.contains('8291'))protected.add('8291');
   await c.command('/ip/firewall/filter/add',args:{'chain':'input','action':'drop','protocol':'tcp','dst-port':protected.join(','),'src-address-list':'!Trusted_Admin','place-before':'0','comment':'NOVA:PORTKNOCK:DROP'});
   await c.command('/ip/firewall/filter/add',args:{'chain':'input','action':'add-src-to-address-list','protocol':'tcp','dst-port':'$b','src-address-list':'NOVA_KNOCK_1','address-list':'Trusted_Admin','address-list-timeout':'1h','place-before':'0','comment':'NOVA:PORTKNOCK:SECOND'});
   await c.command('/ip/firewall/filter/add',args:{'chain':'input','action':'add-src-to-address-list','protocol':'tcp','dst-port':'$a','address-list':'NOVA_KNOCK_1','address-list-timeout':'15s','place-before':'0','comment':'NOVA:PORTKNOCK:FIRST'});
   toast('أُنشئت القواعد. أدخل '+a.toString()+','+b.toString()+' في إعدادات الراوتر لتفعيل الطرق التلقائي.');await _load();
  }catch(e){toast('فشل إنشاء القواعد: '+err(e),bad:true);}finally{if(mounted)setState(()=>busy=false);}
 }
 Future<void> _forward() async {
  final c=client;final n=port(insidePort),o=port(outsidePort),addr=ip.text.trim(),iface=wan.text.trim();
  if(c==null||n==null||o==null||iface.isEmpty||!RegExp(r'^(?:\d{1,3}\.){3}\d{1,3}$').hasMatch(addr)||addr.split('.').any((x)=>int.parse(x)>255)){toast('تحقق من IP والمنفذين وواجهة WAN.',bad:true);return;}
  if(!await confirm('إنشاء DST-NAT؟','سيُعرّض '+protocol.toUpperCase()+' '+o.toString()+' على '+iface+' إلى '+addr+':'+n.toString()+'.'))return;
  setState(()=>busy=true);try{await c.command('/ip/firewall/nat/add',args:{'chain':'dstnat','action':'dst-nat','protocol':protocol,'in-interface':iface,'dst-port':'$o','to-addresses':addr,'to-ports':'$n','comment':'NOVA:PORTFWD:'+protocol+'_'+o.toString()});toast('أُنشئت القاعدة. يلزم Public IP وقاعدة forward تسمح بالمرور.');}
  catch(e){toast(err(e),bad:true);}finally{if(mounted)setState(()=>busy=false);}
 }
 Widget card(String title,Widget child)=>Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:_panel,borderRadius:BorderRadius.circular(16),border:Border.all(color:Colors.white.withOpacity(.07))),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w800)),const SizedBox(height:10),child]));
 InputDecoration dec(String s)=>InputDecoration(labelText:s,labelStyle:const TextStyle(color:_muted,fontSize:12),filled:true,fillColor:const Color(0xFF0B1019),border:OutlineInputBorder(borderRadius:BorderRadius.circular(12)));
 @override Widget build(BuildContext context){
  if(client==null)return Scaffold(backgroundColor:_bg,appBar:AppBar(title:const Text('الأمان الخارجي')),body:const Center(child:Text('اتصل بالراوتر أولاً.')));
  return DefaultTabController(length:3,child:Scaffold(backgroundColor:_bg,appBar:AppBar(backgroundColor:_bg,foregroundColor:Colors.white,title:const Text('الأمان الخارجي'),actions:[IconButton(onPressed:busy?null:_load,icon:const Icon(Icons.refresh,color:_accent))],bottom:const TabBar(isScrollable:true,indicatorColor:_accent,tabs:[Tab(text:'خدمات الإدارة'),Tab(text:'Port Knocking'),Tab(text:'الأجهزة الفرعية')])),body:loading?const Center(child:CircularProgressIndicator(color:_accent)):Column(children:[if(error!=null)Padding(padding:const EdgeInsets.all(8),child:Text(error!,style:const TextStyle(color:_red))),Expanded(child:TabBarView(children:[_serviceTab(),_knockTab(),_forwardTab()]))])));
 }
 Widget _serviceTab()=>ListView(padding:const EdgeInsets.all(12),children:[
  card('خدمات RouterOS',const Text('قيّد الإدارة إلى عناوين موثوقة. لا تستخدم 0.0.0.0/0 إلا إذا كنت تقصد السماح للجميع.',style:TextStyle(color:Colors.white70,fontSize:12))),
  ...services.map((s){final enabled=s['disabled']!='true'&&s['disabled']!='yes';return card((s['name']??'service').toUpperCase(),Column(children:[Row(children:[Expanded(child:Text('TCP • '+(s['port']??'—'),style:const TextStyle(color:Colors.white70))),Switch(value:enabled,activeColor:_accent,onChanged:busy?null:(v)=>_setService(s,disabled:!v)),IconButton(onPressed:busy?null:()=>_edit(s),icon:const Icon(Icons.tune,color:_accent))]),Align(alignment:Alignment.centerRight,child:Text('العناوين: '+(s['address']??'—'),style:const TextStyle(color:_muted,fontSize:11)))]));})]);
 Widget _knockTab()=>ListView(padding:const EdgeInsets.all(12),children:[
  card('قفل سري بترتيب الطرق',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
   const Text('الطرق الأول يضيف المصدر إلى NOVA_KNOCK_1 لمدة 15 ثانية؛ الثاني يضيفه إلى Trusted_Admin لمدة ساعة. ثم تُحجب منافذ API وWinBox عن المصادر الأخرى.',style:TextStyle(color:Colors.white70,fontSize:12,height:1.5)),
   const SizedBox(height:10),Row(children:[Expanded(child:TextField(controller:p1,keyboardType:TextInputType.number,inputFormatters:[FilteringTextInputFormatter.digitsOnly],decoration:dec('الطرق الأول'))),const SizedBox(width:8),Expanded(child:TextField(controller:p2,keyboardType:TextInputType.number,inputFormatters:[FilteringTextInputFormatter.digitsOnly],decoration:dec('الطرق الثاني')))]),
   const SizedBox(height:12),FilledButton.icon(onPressed:busy?null:_knock,style:FilledButton.styleFrom(backgroundColor:knockEnabled?const Color(0xFF49303A):_accent),icon:Icon(knockEnabled?Icons.lock_open:Icons.lock),label:Text(busy?'جارٍ التنفيذ':knockEnabled?'تعطيل القواعد':'تفعيل حماية Port Knocking بضغطة زر')),
   Text(knockEnabled?'الحماية مفعّلة.':'الحماية غير مفعّلة.',style:TextStyle(color:knockEnabled?_green:_muted,fontSize:11))])),
  card('Auto-Knock before Connect',const Text('في شاشة الراوترات افتح تعديل الراوتر وأدخل نفس المنافذ في حقل Port Knocking، مثل 7000,8000. سيطرق التطبيق هذه المنافذ قبل الاتصال.',style:TextStyle(color:Colors.white70,fontSize:12,height:1.5))),
  card('قواعد التطبيق',rules.isEmpty?const Text('لا توجد قواعد NOVA:PORTKNOCK.',style:TextStyle(color:_muted)):Column(children:rules.map((r)=>ListTile(dense:true,title:Text(r['comment']??'Rule',style:const TextStyle(color:Colors.white,fontSize:12)),subtitle:Text('منفذ '+(r['dst-port']??'—'),style:const TextStyle(color:_muted,fontSize:10)),trailing:Text(r['disabled']=='true'?'معطّل':'مفعّل',style:const TextStyle(color:_muted,fontSize:10)))).toList()))]);
 Widget _forwardTab()=>ListView(padding:const EdgeInsets.all(12),children:[
  card('تحويل إلى صحن أو جهاز فرعي',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
   const Text('تضيف هذه الأداة قاعدة DST-NAT فقط. يجب السماح بالمرور في forward وأن يكون عنوان WAN قابلًا للوصول من الإنترنت.',style:TextStyle(color:Colors.white70,fontSize:12,height:1.5)),
   const SizedBox(height:10),TextField(controller:ip,textDirection:TextDirection.ltr,decoration:dec('IP الداخلي')),
   const SizedBox(height:8),Row(children:[Expanded(child:TextField(controller:insidePort,keyboardType:TextInputType.number,inputFormatters:[FilteringTextInputFormatter.digitsOnly],decoration:dec('منفذ الجهاز'))),const SizedBox(width:8),Expanded(child:TextField(controller:outsidePort,keyboardType:TextInputType.number,inputFormatters:[FilteringTextInputFormatter.digitsOnly],decoration:dec('المنفذ الخارجي')))]),
   const SizedBox(height:8),TextField(controller:wan,textDirection:TextDirection.ltr,decoration:dec('واجهة WAN')),
   const SizedBox(height:8),DropdownButtonFormField<String>(value:protocol,dropdownColor:_panel,style:const TextStyle(color:Colors.white),decoration:dec('البروتوكول'),items:const [DropdownMenuItem(value:'tcp',child:Text('TCP')),DropdownMenuItem(value:'udp',child:Text('UDP'))],onChanged:busy?null:(v)=>setState(()=>protocol=v??'tcp')),
   const SizedBox(height:12),FilledButton.icon(onPressed:busy?null:_forward,icon:const Icon(Icons.add_link),label:const Text('إنشاء قاعدة DST-NAT'))])),
  card('تنبيه أمني',const Text('لا تكشف API أو WinBox أو صفحة إدارة الصحن للعالم مباشرة إن أمكن؛ استخدم VPN أو قيّد Source Address. خلف CGNAT لا يكفي DST-NAT وحده.',style:TextStyle(color:_red,fontSize:11,height:1.5)))]);
}
