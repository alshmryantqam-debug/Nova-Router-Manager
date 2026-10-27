import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/providers/router_providers.dart';
import '../../core/storage/router_storage_service.dart';
import 'wireguard_tunnel_service.dart';

class WireguardTunnelScreen extends ConsumerStatefulWidget {
  const WireguardTunnelScreen({super.key});
  @override
  ConsumerState<WireguardTunnelScreen> createState()=>_WireguardTunnelScreenState();
}
class _WireguardTunnelScreenState extends ConsumerState<WireguardTunnelScreen> {
  WireguardTunnelService? _service;
  List<Map<String,String>> _interfaces=[],_peers=[];
  Map<String,String> _cloud={};
  WireguardTunnelResult? _result;
  String? _config,_host,_profileKey,_error;
  bool _loading=true,_busy=false;
  Timer? _timer;
  @override void initState(){
    super.initState();final c=ref.read(activeRouterClientProvider);
    if(c!=null){_service=WireguardTunnelService(c);unawaited(_load());_timer=Timer.periodic(const Duration(seconds:4),(_){if(!_busy)unawaited(_load(silent:true));});}
    else{_loading=false;_error='اتصل بالراوتر أولاً.';}
  }
  @override void dispose(){_timer?.cancel();super.dispose();}
  String _err(Object e)=>e.toString().replaceFirst('RouterOsException: ','');
  void _msg(String s,{bool bad=false}){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s),backgroundColor:bad?Colors.red:Colors.green.shade800));}
  Future<void> _load({bool silent=false}) async {
    final s=_service;if(s==null)return;if(!silent&&mounted)setState(()=>_loading=true);
    try{final i=await s.listInterfaces();final p=await s.listPeers();final c=await s.cloudStatus();if(mounted)setState(() { _interfaces=i; _peers=p; _cloud=c; _loading=false; _error=null; });}
    catch(e){if(mounted)setState(() { _loading=false; _error=_err(e); });}
  }
  Future<void> _create() async {
    if(_service==null||_busy)return;setState(() { _busy=true; _error=null; });
    try{final r=await _service!.createOneClickTunnel();if(mounted)setState(() { _result=r; _config=r.config; _host=r.routerAddress.split('/').first; _profileKey='wg-${r.id}'; });_msg('تم إنشاء النفق. امسح QR بتطبيق WireGuard.');await _load(silent:true);}
    catch(e){if(mounted)setState(()=>_error=_err(e));_msg('تعذر إنشاء النفق: ${_err(e)}',bad:true);}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _bth() async {
    if(_service==null||_busy)return;setState(()=>_busy=true);
    try{final r=await _service!.enableBackToHome();if(mounted)setState(() { _result=null; _config=r.config; _host='192.168.216.1'; _profileKey='bth-${DateTime.now().millisecondsSinceEpoch}'; });_msg('Back To Home جاهز؛ امسح QR.');await _load(silent:true);}
    catch(e){if(mounted)setState(()=>_error=_err(e));_msg('فشل Back To Home: ${_err(e)}',bad:true);}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _copy() async {final c=_config;if(c!=null){await Clipboard.setData(ClipboardData(text:c));_msg('تم نسخ الإعداد؛ لا تشارك الملف لأنه يحتوي على المفتاح الخاص.');}}
  Future<void> _saveRouter() async {
    final active=ref.read(activeRouterDetailsProvider),host=_host,key=_profileKey;if(active==null||host==null||key==null)return;
    setState(()=>_busy=true);
    try{await ref.read(savedRoutersProvider.notifier).saveRouter(SavedRouter(id:'nova-$key-${active.id}',name:'${active.name} • وصول WireGuard',host:host,port:active.port,username:active.username,password:active.password,useSsl:active.useSsl));_msg('تم حفظ الراوتر بعنوان $host. اتصل بالـ VPN أولاً.');}
    catch(e){_msg(_err(e),bad:true);}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<bool> _confirm(String title,String text) async => await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:Text(title),content:Text(text),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('تأكيد'))]))??false;
  Future<void> _toggle(Map<String,String> row) async {
    final s=_service,id=row['.id'];if(s==null||id==null||_busy)return;
    final off=row['disabled']=='true'||row['disabled']=='yes';setState(()=>_busy=true);
    try{if(row['name']=='back-to-home-vpn'){if(!await _confirm('إيقاف Back To Home؟','سيتم إلغاء مفاتيح جميع مستخدمي BTH.'))return;await s.disableBackToHome();}else{await s.setTunnelDisabled(id,!off);}await _load(silent:true);}
    catch(e){_msg(_err(e),bad:true);}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _remove(Map<String,String> row) async {
    final s=_service,id=row['.id'];if(s==null||id==null||_busy)return;
    if(!await _confirm('حذف النفق؟','سيُحذف النفق وأقرانه والعناوين وقواعد NOVA التابعة له.'))return;
    setState(()=>_busy=true);try{await s.removeTunnel(id);if(_result?.interfaceId==id)setState(() { _result=null; _config=null; _host=null; _profileKey=null; });await _load(silent:true);}
    catch(e){_msg(_err(e),bad:true);}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _peerAction(Map<String,String> row,{required bool delete}) async {
    final s=_service,id=row['.id'];if(s==null||id==null||_busy||row['dynamic']=='true')return;
    if(delete&&!await _confirm('حذف المستخدم؟','سيُلغى مفتاح WireGuard لهذا المستخدم.'))return;
    setState(()=>_busy=true);try{if(delete){await s.removePeer(id);}else{await s.setPeerDisabled(id,!(row['disabled']=='true'||row['disabled']=='yes'));}await _load(silent:true);}
    catch(e){_msg(_err(e),bad:true);}finally{if(mounted)setState(()=>_busy=false);}
  }
  Widget _card(String title,Widget child)=>Card(color:const Color(0xFF111722),child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.bold)),const SizedBox(height:10),child])));
  @override Widget build(BuildContext context){
    if(ref.watch(activeRouterClientProvider)==null||_service==null)return const Scaffold(body:Center(child:Text('اتصل بالراوتر أولاً.')));
    return Scaffold(backgroundColor:const Color(0xFF080B12),appBar:AppBar(title:const Text('الوصول الخارجي والأنفاق'),actions:[IconButton(onPressed:_busy?null:()=>_load(),icon:const Icon(Icons.refresh))]),
      body:_loading?const Center(child:CircularProgressIndicator()):RefreshIndicator(onRefresh:()=>_load(),child:ListView(padding:const EdgeInsets.all(12),children:[
        if(_error!=null)Text(_error!,style:const TextStyle(color:Colors.red)),
        _card('One-Click WireGuard Tunnel',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          const Text('ينشئ واجهة 10.200.200.1/24، ومفتاح عميل، وقاعدة UDP 13231 مع السماح للعميل الجديد بالوصول إلى الراوتر فقط.',style:TextStyle(color:Colors.white70)),
          const SizedBox(height:8),FilledButton.icon(onPressed:_busy?null:_create,icon:const Icon(Icons.rocket_launch),label:const Text('إنشاء نفق وصول خارجي بضغطة زر (1-Click Remote Tunnel)')),
          OutlinedButton.icon(onPressed:_busy?null:_bth,icon:const Icon(Icons.cloud_sync),label:const Text('Back To Home VPN (بديل عند CGNAT)'))
        ])),
        if(_config!=null&&_config!.isNotEmpty)_card('QR وملف .conf',Column(children:[
          Container(color:Colors.white,padding:const EdgeInsets.all(8),child:QrImageView(data:_config!,version:QrVersions.auto,size:230,backgroundColor:Colors.white)),
          const SizedBox(height:8),SelectableText(_config!,style:const TextStyle(color:Colors.lightGreenAccent,fontSize:10,fontFamily:'monospace')),
          FilledButton.icon(onPressed:_copy,icon:const Icon(Icons.copy),label:const Text('نسخ ملف الإعدادات (.conf)')),
          OutlinedButton.icon(onPressed:_busy?null:_saveRouter,icon:const Icon(Icons.bookmark_add),label:const Text('حفظ اتصال الراوتر في التطبيق'))
        ])),
        _card('حالة IP Cloud',Text('VPN: ${_cloud['vpn-status']??'—'} • DDNS: ${_cloud['ddns-enabled']??'—'}\nEndpoint: ${_cloud['vpn-dns-name']??_cloud['dns-name']??'—'} • Port: ${_cloud['vpn-port']??'—'}',style:const TextStyle(color:Colors.white70))),
        _card('واجهات WireGuard (${_interfaces.length})',Column(children:_interfaces.isEmpty?[const Text('لا توجد واجهات.',style:TextStyle(color:Colors.white70))]:_interfaces.map((r)=>ListTile(
          title:Text(r['name']??'—',style:const TextStyle(color:Colors.white)),subtitle:Text('port ${r['listen-port']??'—'} • ${r['disabled']=='true'?'معطل':'مفعّل'}',style:const TextStyle(color:Colors.white60)),
          trailing:Wrap(children:[IconButton(onPressed:_busy?null:()=>_toggle(r),icon:const Icon(Icons.power_settings_new)),IconButton(onPressed:_busy?null:()=>_remove(r),icon:const Icon(Icons.delete_outline,color:Colors.redAccent))]))).toList())),
        _card('WireGuard Peers (${_peers.length})',Column(children:_peers.isEmpty?[const Text('لا توجد أقران.',style:TextStyle(color:Colors.white70))]:_peers.map((r)=>ListTile(
          title:Text(r['name']?.isNotEmpty==true?r['name']!:r['public-key']??'Peer',style:const TextStyle(color:Colors.white)),
          subtitle:Text('${r['interface']??'—'} • ${r['allowed-address']??'—'}\nHandshake: ${r['last-handshake']??'never'} • RX ${r['rx']??'0'} / TX ${r['tx']??'0'}',style:const TextStyle(color:Colors.white60,fontSize:10)),
          trailing:r['dynamic']=='true'?null:Wrap(children:[IconButton(onPressed:_busy?null:()=>_peerAction(r,delete:false),icon:const Icon(Icons.pause)),IconButton(onPressed:_busy?null:()=>_peerAction(r,delete:true),icon:const Icon(Icons.delete_outline,color:Colors.redAccent))]))).toList())),
        const Padding(padding:EdgeInsets.all(8),child:Text('QR وملف .conf يحتويان على مفتاح العميل الخاص. لا تشاركهما. قد يحتاج الاتصال المباشر إلى Public IP أو Port Forward؛ Back To Home يستخدم وسيط MikroTik عند الحاجة.',style:TextStyle(color:Colors.white60,fontSize:11)))
      ])));
  }
}
