import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const _bg=Color(0xFF080B12), _panel=Color(0xFF111722), _muted=Color(0xFF8D9AB0), _accent=Color(0xFF8B7CFF), _rx=Color(0xFF43D9A3), _tx=Color(0xFF67B7FF), _danger=Color(0xFFFF657A);
enum _SortMode { download, upload, data, oldest, newest }
class _LiveUser {
 const _LiveUser({required this.kind,required this.name,required this.address,required this.mac,required this.comment,required this.uptime,required this.rxMbps,required this.txMbps,required this.bytes,required this.id,required this.secretId,required this.queueId,required this.activeId});
 final String kind,name,address,mac,comment,uptime,id,secretId,queueId,activeId;
 final double rxMbps,txMbps; final int bytes;
}
class UnifiedActiveUsersScreen extends ConsumerStatefulWidget {
 const UnifiedActiveUsersScreen({super.key});
 @override ConsumerState<UnifiedActiveUsersScreen> createState()=>_UnifiedActiveUsersScreenState();
}
class _UnifiedActiveUsersScreenState extends ConsumerState<UnifiedActiveUsersScreen> {
 final _search=TextEditingController(); Timer? _timer; bool _loading=true,_busy=false; String? _error; _SortMode _sort=_SortMode.download; List<_LiveUser> _users=[]; RouterOsClient? _client;
 @override void initState(){super.initState();_client=ref.read(activeRouterClientProvider);unawaited(_refresh());_timer=Timer.periodic(const Duration(seconds:3),(_)=>_refresh(silent:true));}
 @override void dispose(){_timer?.cancel();_search.dispose();super.dispose();}
 int _int(String? s)=>int.tryParse((s??'').replaceAll(RegExp(r'[^0-9]'),''))??0;
 double _mbps(String? s)=>_int(s)/1000000;
 String _first(Map<String,String> r,List<String> keys){for(final k in keys){final v=r[k];if(v!=null&&v.trim().isNotEmpty)return v.trim();}return '';}
 Future<List<Map<String,String>>> _read(RouterOsClient c,String path,String props) async {try{return await c.command(path,args:{'.proplist':props});}catch(_){return <Map<String,String>>[];}}
 Future<void> _refresh({bool silent=false}) async {
  final c=ref.read(activeRouterClientProvider);
  if(c==null){if(mounted)setState(() {_loading=false; _error='اتصل براوتر أولاً.';});return;}
  if(!identical(c,_client))_client=c;
  if(!silent&&mounted)setState(() {_loading=true; _error=null;});
  try{
   final r=await Future.wait<List<Map<String,String>>>([
    _read(c,'/ppp/active/print','.id,name,address,caller-id,uptime,bytes-in,bytes-out'),
    _read(c,'/ppp/secret/print','.id,name,comment,disabled,caller-id'),
    _read(c,'/ip/hotspot/active/print','.id,user,address,mac-address,uptime,bytes-in,bytes-out'),
    _read(c,'/ip/hotspot/user/print','.id,name,comment,disabled,mac-address'),
    _read(c,'/queue/simple/print','.id,name,dynamic,target,rate,bytes,comment'),
   ]);
   final ps={for(final x in r[1]) (x['name']??''):x};final hs={for(final x in r[3]) (x['name']??''):x};final qmap=<String,Map<String,String>>{};
   for(final q in r[4]){final n=q['name']??'';if(n.startsWith('<pppoe-')&&n.endsWith('>'))qmap[n.substring(7,n.length-1)]=q;}
   final users=<_LiveUser>[];final usedQueues=<String>{};
   for(final a in r[0]){final n=a['name']??'';if(n.isEmpty)continue;final sec=ps[n]??const <String,String>{};final q=qmap[n];if(q!=null)usedQueues.add(q['name']??'');final rate=(q?['rate']??'0/0').split('/');
    users.add(_LiveUser(kind:'PPPoE',name:n,address:a['address']??'',mac:_first(a,['caller-id']).isNotEmpty?a['caller-id']!:sec['caller-id']??'',comment:sec['comment']??'',uptime:a['uptime']??'',rxMbps:rate.length>1?_mbps(rate[1]):0,txMbps:rate.isNotEmpty?_mbps(rate[0]):0,bytes:_int(a['bytes-in'])+_int(a['bytes-out']),id:a['.id']??'',secretId:sec['.id']??'',queueId:q?['.id']??'',activeId:a['.id']??''));
   }
   for(final a in r[2]){final n=_first(a,['user','name']);if(n.isEmpty)continue;final sec=hs[n]??const <String,String>{};
    users.add(_LiveUser(kind:'Hotspot',name:n,address:a['address']??'',mac:a['mac-address']??sec['mac-address']??'',comment:sec['comment']??'',uptime:a['uptime']??'',rxMbps:0,txMbps:0,bytes:_int(a['bytes-in'])+_int(a['bytes-out']),id:sec['.id']??'',secretId:sec['.id']??'',queueId:'',activeId:a['.id']??''));
   }
   for(final q in r[4]){final n=q['name']??'';if(n.isEmpty||usedQueues.contains(n)||n.startsWith('<pppoe-'))continue;final rate=(q['rate']??'0/0').split('/');final bytes=(q['bytes']??'0/0').split('/');
    users.add(_LiveUser(kind:'Simple Queue',name:n,address:q['target']??'',mac:'',comment:q['comment']??'',uptime:'—',rxMbps:rate.length>1?_mbps(rate[1]):0,txMbps:rate.isNotEmpty?_mbps(rate[0]):0,bytes:bytes.fold<int>(0,(sum,v)=>sum+_int(v)),id:q['.id']??'',secretId:'',queueId:q['.id']??'',activeId:''));
   }
   if(mounted)setState(() {_users=users; _loading=false; _error=null;});
  }catch(e){if(mounted)setState(() {_loading=false; _error=e.toString();});}
 }
 Future<void> _act(String label,Future<void> Function(RouterOsClient) fn) async {final c=ref.read(activeRouterClientProvider);if(c==null||_busy)return;setState(() {_busy=true; _error=null;});try{await fn(c);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('$label: تم التنفيذ')));await _refresh(silent:true);}catch(e){if(mounted)setState(()=>_error='$label: $e');}finally{if(mounted)setState(()=>_busy=false);}}
 Future<void> _rate(_LiveUser u) async {
  final ctl=TextEditingController(text:'5M/5M');final v=await showDialog<String>(context:context,builder:(ctx)=>AlertDialog(backgroundColor:_panel,title:Text('تحديد السرعة: ${u.name}',style:const TextStyle(color:Colors.white)),content:Column(mainAxisSize:MainAxisSize.min,children:[Wrap(spacing:5,children:['2M/2M','5M/5M','10M/10M'].map((x)=>ActionChip(label:Text(x),onPressed:()=>Navigator.pop(ctx,x))).toList()),TextField(controller:ctl,style:const TextStyle(color:Colors.white),decoration:const InputDecoration(hintText:'Upload/Download'))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,ctl.text.trim()),child:const Text('تطبيق'))]));ctl.dispose();if(v==null||v.isEmpty)return;if(!RegExp(r'^\d+(?:\.\d+)?[kMGT]?/\d+(?:\.\d+)?[kMGT]?$').hasMatch(v)){setState(()=>_error='صيغة السرعة غير صحيحة');return;}
  await _act('تحديد السرعة',(c)async{if(u.queueId.isNotEmpty){await c.command('/queue/simple/set',args:{'.id':u.queueId,'max-limit':v});}else if(u.kind=='Hotspot'&&u.secretId.isNotEmpty){final rows=await c.command('/ip/hotspot/user/print',args:{'.proplist':'profile','numbers':u.secretId});final p=rows.isEmpty?'':rows.first['profile']??'';final profiles=await c.command('/ip/hotspot/user/profile/print',args:{'.proplist':'.id,name','?name':p});if(profiles.isEmpty)throw StateError('لم يتم العثور على باقة المستخدم');await c.command('/ip/hotspot/user/profile/set',args:{'.id':profiles.first['.id']??'','rate-limit':v});}else{throw StateError('لا يوجد طابور قابل لتغيير السرعة');}});
 }
 Future<void> _macKick(_LiveUser u)=>_act('تصفير MAC وإعادة التنشيط',(c)async{if(u.kind=='PPPoE'){if(u.secretId.isNotEmpty)await c.command('/ppp/secret/set',args:{'.id':u.secretId,'caller-id':''});if(u.activeId.isNotEmpty)await c.command('/ppp/active/remove',args:{'.id':u.activeId});}else if(u.kind=='Hotspot'){if(u.secretId.isNotEmpty)await c.command('/ip/hotspot/user/set',args:{'.id':u.secretId,'mac-address':''});if(u.activeId.isNotEmpty)await c.command('/ip/hotspot/active/remove',args:{'.id':u.activeId});final cookies=await c.command('/ip/hotspot/cookie/print',args:{'.proplist':'.id,user','?user':u.name});for(final x in cookies){if((x['.id']??'').isNotEmpty)await c.command('/ip/hotspot/cookie/remove',args:{'.id':x['.id']!});}}else{throw StateError('لا يوجد MAC لحساب طابور عام');}});
 Future<void> _disable(_LiveUser u)=>_act('تعطيل اليوزر',(c)async{if(u.kind=='PPPoE'){if(u.secretId.isEmpty)throw StateError('حساب PPPoE غير موجود');await c.command('/ppp/secret/disable',args:{'.id':u.secretId});if(u.activeId.isNotEmpty)await c.command('/ppp/active/remove',args:{'.id':u.activeId});}else if(u.kind=='Hotspot'){if(u.secretId.isEmpty)throw StateError('حساب Hotspot غير موجود');await c.command('/ip/hotspot/user/disable',args:{'.id':u.secretId});if(u.activeId.isNotEmpty)await c.command('/ip/hotspot/active/remove',args:{'.id':u.activeId});}else{throw StateError('الطابور العام ليس حساب مستخدم');}});
 int _up(String s){var n=0;for(final m in RegExp(r'(\d+)([wdhms])').allMatches(s)){final v=int.tryParse(m.group(1)!)??0;switch(m.group(2)){case'w':n+=v*604800;break;case'd':n+=v*86400;break;case'h':n+=v*3600;break;case'm':n+=v*60;break;case's':n+=v;break;}}return n;}
 String _bytes(int n)=>n>=1073741824?'${(n/1073741824).toStringAsFixed(2)} GB':n>=1048576?'${(n/1048576).toStringAsFixed(1)} MB':'${(n/1024).toStringAsFixed(0)} KB';
 @override Widget build(BuildContext context){
  final q=_search.text.trim().toLowerCase();final list=_users.where((u)=>q.isEmpty||[u.name,u.address,u.mac,u.comment].any((x)=>x.toLowerCase().contains(q))).toList();
  list.sort((a,b)=>switch(_sort){_SortMode.download=>b.rxMbps.compareTo(a.rxMbps),_SortMode.upload=>b.txMbps.compareTo(a.txMbps),_SortMode.data=>b.bytes.compareTo(a.bytes),_SortMode.oldest=>_up(b.uptime).compareTo(_up(a.uptime)),_SortMode.newest=>_up(a.uptime).compareTo(_up(b.uptime))});
  return Scaffold(backgroundColor:_bg,appBar:AppBar(backgroundColor:_bg,foregroundColor:Colors.white,title:const Text('مراقب اليوزرات والسرعات الحي'),actions:[IconButton(onPressed:()=>_refresh(),icon:const Icon(Icons.refresh,color:_accent))]),body:Column(children:[
   Padding(padding:const EdgeInsets.all(12),child:TextField(controller:_search,onChanged:(_)=>setState((){}),style:const TextStyle(color:Colors.white),decoration:InputDecoration(prefixIcon:const Icon(Icons.search,color:_muted),hintText:'بحث بالاسم أو IP أو MAC أو comment',hintStyle:const TextStyle(color:_muted,fontSize:12),filled:true,fillColor:_panel,border:OutlineInputBorder(borderRadius:BorderRadius.circular(14),borderSide:BorderSide.none)))),
   Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:DropdownButtonFormField<_SortMode>(value:_sort,dropdownColor:_panel,style:const TextStyle(color:Colors.white),decoration:const InputDecoration(labelText:'ترتيب القائمة',labelStyle:TextStyle(color:_muted)),items:const [DropdownMenuItem(value:_SortMode.download,child:Text('الأعلى Download')),DropdownMenuItem(value:_SortMode.upload,child:Text('الأعلى Upload')),DropdownMenuItem(value:_SortMode.data,child:Text('الأعلى استهلاكاً')),DropdownMenuItem(value:_SortMode.oldest,child:Text('أقدم اتصال')),DropdownMenuItem(value:_SortMode.newest,child:Text('أحدث اتصال'))],onChanged:(v){if(v!=null)setState(()=>_sort=v);})),
   if(_error!=null)Padding(padding:const EdgeInsets.all(8),child:Text(_error!,style:const TextStyle(color:_danger,fontSize:11))),if(_busy)const LinearProgressIndicator(color:_accent),
   Padding(padding:const EdgeInsets.all(10),child:Row(children:[_summary('الجميع',_users.length.toString(),_accent),_summary('PPPoE',_users.where((u)=>u.kind=='PPPoE').length.toString(),_tx),_summary('Hotspot',_users.where((u)=>u.kind=='Hotspot').length.toString(),_rx)])),
   Expanded(child:_loading&&_users.isEmpty?const Center(child:CircularProgressIndicator(color:_accent)):RefreshIndicator(onRefresh:()=>_refresh(),child:list.isEmpty?ListView(children:[const SizedBox(height:100),const Center(child:Text('لا توجد نتائج',style:TextStyle(color:_muted)))]):ListView.builder(itemCount:list.length,itemBuilder:(ctx,i)=>_card(list[i]))))
  ]));
 }
 Widget _summary(String label,String value,Color color)=>Expanded(child:Container(margin:const EdgeInsets.symmetric(horizontal:3),padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:_panel,borderRadius:BorderRadius.circular(12)),child:Column(children:[Text(value,style:TextStyle(color:color,fontSize:18,fontWeight:FontWeight.w900)),Text(label,style:const TextStyle(color:_muted,fontSize:10))])));
 Widget _card(_LiveUser u){final color=u.kind=='PPPoE'?_accent:u.kind=='Hotspot'?_rx:_tx;final progress=((u.rxMbps+u.txMbps)/10).clamp(0.0,1.0).toDouble();return Container(margin:const EdgeInsets.fromLTRB(12,3,12,7),padding:const EdgeInsets.all(12),decoration:BoxDecoration(color:_panel,borderRadius:BorderRadius.circular(15),border:Border.all(color:color.withOpacity(.25))),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
  Row(children:[Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),decoration:BoxDecoration(color:color.withOpacity(.15),borderRadius:BorderRadius.circular(8)),child:Text(u.kind,style:TextStyle(color:color,fontSize:10,fontWeight:FontWeight.w800))),const SizedBox(width:8),Expanded(child:Text(u.name,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w800),maxLines:1,overflow:TextOverflow.ellipsis)),PopupMenuButton<String>(icon:const Icon(Icons.more_vert,color:_muted),onSelected:(v){if(v=='rate')_rate(u);if(v=='mac')_macKick(u);if(v=='disable')_disable(u);},itemBuilder:(_)=>const [PopupMenuItem(value:'rate',child:Text('تحديد السرعة فوراً')),PopupMenuItem(value:'mac',child:Text('تصفير MAC وإعادة التنشيط')),PopupMenuItem(value:'disable',child:Text('حظر / تعطيل اليوزر'))])]),
  Text(u.address.isEmpty?'IP غير متاح':u.address,style:const TextStyle(color:_muted,fontSize:11)),if(u.mac.isNotEmpty)Text('MAC: ${u.mac}',style:const TextStyle(color:_muted,fontSize:10)),if(u.comment.isNotEmpty)Text(u.comment,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:_muted,fontSize:10)),
  const SizedBox(height:8),Row(children:[Expanded(child:Text('RX ${u.rxMbps.toStringAsFixed(2)} Mbps',style:const TextStyle(color:_rx,fontSize:11))),Expanded(child:Text('TX ${u.txMbps.toStringAsFixed(2)} Mbps',style:const TextStyle(color:_tx,fontSize:11))),Text(_bytes(u.bytes),style:const TextStyle(color:Colors.white,fontSize:11,fontWeight:FontWeight.w700))]),const SizedBox(height:5),ClipRRect(borderRadius:BorderRadius.circular(9),child:LinearProgressIndicator(value:progress,minHeight:5,backgroundColor:Colors.white.withOpacity(.06),valueColor:AlwaysStoppedAnimation<Color>(progress>.75?_danger:color))),Text('Uptime: ${u.uptime}',style:const TextStyle(color:_muted,fontSize:10))
 ]));}
}
