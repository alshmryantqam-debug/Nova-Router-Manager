import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/router_providers.dart';

const _bg=Color(0xFF080B12), _panel=Color(0xFF111722), _accent=Color(0xFF8B7CFF), _muted=Color(0xFF8D9AB0);
class GlobalSearchScreen extends ConsumerStatefulWidget {
 const GlobalSearchScreen({super.key});
 @override ConsumerState<GlobalSearchScreen> createState()=>_GlobalSearchScreenState();
}
class _GlobalSearchScreenState extends ConsumerState<GlobalSearchScreen>{
 final _query=TextEditingController(); Timer? _debounce; bool _loading=false,_working=false; String? _error,_message; List<_Hit> _hits=[];
 @override void dispose(){_debounce?.cancel();_query.dispose();super.dispose();}
 void _changed(String s){_debounce?.cancel();_debounce=Timer(const Duration(milliseconds:250),_search);}
 Future<List<Map<String,String>>> _read(dynamic c,String path) async {try{return await c.command(path,args:const {'.proplist':'.id,name,user,username,address,mac-address,caller-id,profile,disabled,server,comment,host-name,status'});}catch(_){return <Map<String,String>>[];}}
 bool _match(Map<String,String> r,String q)=>r.values.any((v)=>v.toLowerCase().contains(q.toLowerCase()));
 String _get(Map<String,String> r,List<String> keys)=>keys.map((k)=>r[k]??'').firstWhere((v)=>v.trim().isNotEmpty,orElse:()=> '');
 String _name(_Hit h)=>_get(h.row,['name','user','username']);
 Future<void> _search() async {
  final q=_query.text.trim();final c=ref.read(activeRouterClientProvider);
  if(q.isEmpty){if(mounted)setState(()=>_hits=[]);return;} if(c==null){setState(()=>_error='اتصل براوتر أولاً.');return;}
  setState(() {_loading=true; _error=null; _message=null;});
  try{final rs=await Future.wait([_read(c,'/ip/hotspot/user'),_read(c,'/ip/hotspot/active'),_read(c,'/ppp/secret'),_read(c,'/ppp/active'),_read(c,'/ip/dhcp-server/lease')]);
   final found=<_Hit>[];for(var i=0;i<rs.length;i++){final kinds=['Hotspot User','Hotspot Active','PPPoE Secret','PPPoE Active','DHCP Lease'];final paths=['/ip/hotspot/user','/ip/hotspot/active','/ppp/secret','/ppp/active','/ip/dhcp-server/lease'];for(final row in rs[i]){if(_match(row,q))found.add(_Hit(kinds[i],paths[i],row));}}
   if(mounted)setState(() {_hits=found;});
  }catch(e){if(mounted)setState(()=>_error='فشل البحث: $e');}finally{if(mounted)setState(()=>_loading=false);}
 }
 Future<void> _action(String label,_Hit h,Future<void> Function(dynamic,_Hit) work) async {
  final c=ref.read(activeRouterClientProvider);if(c==null)return;
  setState(() {_working=true; _error=null; _message=null;});
  try{await work(c,h);if(mounted)setState(()=>_message='$label: تم التنفيذ.');await _search();}
  catch(e){if(mounted)setState(()=>_error='$label: $e');}finally{if(mounted)setState(()=>_working=false);}
 }
 Future<void> _mac(dynamic c,_Hit h) async {
  final n=_name(h);if(n.isEmpty)throw Exception('اسم الحساب غير متوفر.');
  final hotspot=h.kind.startsWith('Hotspot');final ppp=h.kind.startsWith('PPPoE');if(!hotspot&&!ppp)throw Exception('اختر حساباً من Hotspot User أو PPPoE Secret.');
  final path=hotspot?'/ip/hotspot/user':'/ppp/secret';final rows=await c.command('$path/print',args:{'?name':n,'.proplist':'.id,name'});if(rows.isEmpty)throw Exception('الحساب غير موجود.');
  await c.command('$path/set',args:{'.id':rows.first['.id']??'','${hotspot?'mac-address':'caller-id'}':''});
 }
 Future<void> _kick(dynamic c,_Hit h) async {
  if(h.kind=='Hotspot Active'||h.kind=='PPPoE Active'){final path=h.kind=='Hotspot Active'?'/ip/hotspot/active/remove':'/ppp/active/remove';final id=h.row['.id'];if(id==null||id.isEmpty)throw Exception('معرّف الجلسة غير متوفر.');await c.command(path,args:{'.id':id});return;}
  final n=_name(h);if(n.isEmpty)throw Exception('اسم الحساب غير متوفر.');
  for(final pair in [['/ip/hotspot/active/print','/ip/hotspot/active/remove','?user'],['/ppp/active/print','/ppp/active/remove','?name']]){final rows=await c.command(pair[0],args:{pair[2]:n,'.proplist':'.id'});for(final row in rows){if((row['.id']??'').isNotEmpty)await c.command(pair[1],args:{'.id':row['.id']!});}}
 }
 Future<void> _toggle(dynamic c,_Hit h) async {
  final hotspot=h.kind=='Hotspot User',ppp=h.kind=='PPPoE Secret';if(!hotspot&&!ppp)throw Exception('اختر Hotspot User أو PPPoE Secret.');
  final path=hotspot?'/ip/hotspot/user':'/ppp/secret';final rows=await c.command('$path/print',args:{'?name':_name(h),'.proplist':'.id,disabled'});if(rows.isEmpty)throw Exception('الحساب غير موجود.');
  final id=rows.first['.id']??'';await c.command('$path/${rows.first['disabled']=='true'?'enable':'disable'}',args:{'.id':id});
 }
 Future<void> _speed(_Hit hit) async {
  final ctl=TextEditingController(text:_get(hit.row,['profile']));
  final value=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(title:const Text('تعديل السرعة'),content:TextField(controller:ctl,decoration:const InputDecoration(labelText:'اسم Profile السرعة')),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,ctl.text.trim()),child:const Text('تطبيق'))]));
  if(value==null||value.isEmpty)return;await _action('تعديل السرعة',hit,(c,h)async{final hs=h.kind=='Hotspot User',pp=h.kind=='PPPoE Secret';if(!hs&&!pp)throw Exception('اختر حساباً قابلاً للتعديل.');final p=hs?'/ip/hotspot/user':'/ppp/secret';final rows=await c.command('$p/print',args:{'?name':_name(h),'.proplist':'.id'});if(rows.isEmpty)throw Exception('الحساب غير موجود.');await c.command('$p/set',args:{'.id':rows.first['.id']??'','profile':value});});
 }
 @override Widget build(BuildContext context)=>Scaffold(backgroundColor:_bg,appBar:AppBar(backgroundColor:_bg,title:const Text('البحث الشامل')),body:ListView(padding:const EdgeInsets.all(16),children:[
  TextField(controller:_query,onChanged:_changed,onSubmitted:(_)=>_search(),autofocus:true,decoration:InputDecoration(hintText:'اسم، كود كرت، IP أو MAC...',prefixIcon:const Icon(Icons.search),suffixIcon:IconButton(onPressed:(){_query.clear();setState(()=>_hits=[]);},icon:const Icon(Icons.clear)),filled:true,fillColor:_panel,border:OutlineInputBorder(borderRadius:BorderRadius.circular(15),borderSide:BorderSide.none))),
  if(_loading)const LinearProgressIndicator(),if(_error!=null)Text(_error!,style:const TextStyle(color:Colors.redAccent)),if(_message!=null)Text(_message!,style:const TextStyle(color:Colors.greenAccent)),
  if(!_loading&&_query.text.isNotEmpty&&_hits.isEmpty&&_error==null)const Padding(padding:EdgeInsets.all(18),child:Text('لا توجد نتائج.',textAlign:TextAlign.center)),
  for(final h in _hits)Card(color:_panel,child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
   Text('${_name(h).isEmpty?h.kind:_name(h)}  ·  ${h.kind}',style:const TextStyle(color:Colors.white,fontSize:16,fontWeight:FontWeight.w800)),
   const SizedBox(height:8),Text('IP: ${_get(h.row,['address'])}  |  MAC: ${_get(h.row,['mac-address','caller-id'])}',style:const TextStyle(color:_muted,fontSize:12)),
   Text('Profile: ${_get(h.row,['profile'])}  |  الحالة: ${h.row['disabled']=='true'?'معطّل':'مفعّل/غير محدد'}',style:const TextStyle(color:_muted,fontSize:12)),
   const SizedBox(height:12),Wrap(spacing:6,runSpacing:6,children:[
    _btn('تصفير الماك',Icons.restart_alt,()=>_action('تصفير MAC',h,_mac)),_btn('طرد الجلسة',Icons.person_remove_alt_1,()=>_action('فصل الجلسة',h,_kick)),_btn('إيقاف / تفعيل',Icons.power_settings_new,()=>_action('تغيير حالة الحساب',h,_toggle)),_btn('تعديل السرعة',Icons.speed,()=>_speed(h)),
   ])
  ]))),
  if(_query.text.isEmpty)const Padding(padding:EdgeInsets.only(top:28),child:Text('ابحث باسم المشترك أو كود الكرت أو IP أو MAC.',textAlign:TextAlign.center,style:TextStyle(color:_muted)))
 ]));
 Widget _btn(String label,IconData icon,VoidCallback tap)=>OutlinedButton.icon(onPressed:_working?null:tap,icon:Icon(icon,size:16),label:Text(label));
}
class _Hit{const _Hit(this.kind,this.path,this.row);final String kind,path;final Map<String,String> row;}
