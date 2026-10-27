import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const _bg=Color(0xFF080B12),_panel=Color(0xFF111722),_accent=Color(0xFF8B7CFF),_muted=Color(0xFF8D9AB0),_green=Color(0xFF43D9A3),_red=Color(0xFFFF657A);

class RawQosWizardScreen extends ConsumerStatefulWidget {
  const RawQosWizardScreen({super.key});
  @override ConsumerState<RawQosWizardScreen> createState()=>_RawQosWizardScreenState();
}
class _RawQosWizardScreenState extends ConsumerState<RawQosWizardScreen> {
  RouterOsClient? get _client=>ref.read(activeRouterClientProvider);
  final _upload=TextEditingController(text:'100');
  final _download=TextEditingController(text:'300');
  bool _busy=false,_loading=true;
  List<Map<String,String>> _raw=[],_filter=[],_mangle=[],_trees=[],_types=[];
  String? _error;

  @override void initState(){super.initState();_load();}
  @override void dispose(){_upload.dispose();_download.dispose();super.dispose();}
  String _err(Object e)=>e.toString().replaceFirst('RouterOsException: ','');
  void _toast(String s,{bool bad=false}){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s),backgroundColor:bad?_red:const Color(0xFF1A443C),behavior:SnackBarBehavior.floating));}
  Future<void> _load() async{
    final c=_client;if(c==null){if(mounted)setState(()=>_loading=false);return;}
    if(mounted)setState(()=>_loading=true);
    try{
      final r=await Future.wait([
        c.command('/ip/firewall/raw/print'),
        c.command('/ip/firewall/filter/print'),
        c.command('/ip/firewall/mangle/print'),
        c.command('/queue/tree/print'),
        c.command('/queue/type/print'),
      ]);
      if(!mounted)return;
      setState((){_raw=r[0];_filter=r[1];_mangle=r[2];_trees=r[3];_types=r[4];_loading=false;_error=null;});
    }catch(e){if(mounted)setState((){_loading=false;_error=_err(e);});}
  }
  bool _hasTag(List<Map<String,String>> rows,String prefix)=>rows.any((r)=>(r['comment']??'').startsWith(prefix));
  Future<bool> _confirm(String title,String body) async=>await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(backgroundColor:_panel,title:Text(title),content:Text(body,style:const TextStyle(height:1.5)),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('متابعة'))]))??false;
  Future<void> _add(String path,Map<String,String> args) async{await _client!.command(path,args:args);}
  Future<void> _applyShield() async{
    final c=_client;if(c==null||_busy)return;
    if(_hasTag(_raw,'NOVA:RAW:SHIELD:')||_hasTag(_filter,'NOVA:RAW:DETECT:')){_toast('قواعد درع Flood موجودة مسبقاً؛ استخدم تعطيل/حذف القواعد من هذه الشاشة قبل إعادة الإضافة.',bad:true);return;}
    if(!await _confirm('تفعيل درع RAW ضد Flood؟','سيحد هذا من SYN وICMP الموجّهين إلى الراوتر بمعدلات عامة، ويضع مصادر الماسح وSYN كثيف الاتصالات في قوائم حظر. افحص القواعد بعد التطبيق؛ الحدود لا تناسب كل شبكة.'))return;
    setState(()=>_busy=true);
    try{
      // Add drops first; the following limited accepts are inserted above them.
      await _add('/ip/firewall/raw/add',{'chain':'prerouting','in-interface-list':'WAN','dst-address-type':'local','protocol':'tcp','tcp-flags':'syn,!ack','action':'drop','comment':'NOVA:RAW:SHIELD:SYN-LIMIT-DROP'});
      await _add('/ip/firewall/raw/add',{'chain':'prerouting','in-interface-list':'WAN','dst-address-type':'local','protocol':'icmp','action':'drop','comment':'NOVA:RAW:SHIELD:ICMP-LIMIT-DROP'});
      await _add('/ip/firewall/raw/add',{'chain':'prerouting','in-interface-list':'WAN','dst-address-type':'local','protocol':'tcp','tcp-flags':'syn,!ack','limit':'100,200:packet','action':'accept','place-before':'0','comment':'NOVA:RAW:SHIELD:SYN-LIMIT-ACCEPT'});
      await _add('/ip/firewall/raw/add',{'chain':'prerouting','in-interface-list':'WAN','dst-address-type':'local','protocol':'icmp','limit':'30,60:packet','action':'accept','place-before':'0','comment':'NOVA:RAW:SHIELD:ICMP-LIMIT-ACCEPT'});
      // Dynamic-list drops must be above the limited accept rules.
      for(final list in const ['NOVA_SYN_FLOOD','NOVA_PORT_SCANNERS']){
        await _add('/ip/firewall/raw/add',{'chain':'prerouting','in-interface-list':'WAN','src-address-list':list,'action':'drop','place-before':'0','comment':'NOVA:RAW:SHIELD:BLACKLIST:'+list});
      }
      await _add('/ip/firewall/filter/add',{'chain':'input','in-interface-list':'WAN','protocol':'tcp','tcp-flags':'syn,!ack','connection-state':'new','connection-limit':'100,32','action':'add-src-to-address-list','address-list':'NOVA_SYN_FLOOD','address-list-timeout':'10m','comment':'NOVA:RAW:DETECT:SYN'});
      await _add('/ip/firewall/filter/add',{'chain':'input','in-interface-list':'WAN','protocol':'tcp','psd':'21,3s,3,1','action':'add-src-to-address-list','address-list':'NOVA_PORT_SCANNERS','address-list-timeout':'1d','comment':'NOVA:RAW:DETECT:PSD'});
      _toast('أُضيفت قواعد درع RAW ومكتشف الماسحات. راجع ترتيبها في RouterOS.');
      await _load();
    }catch(e){_toast('قد تكون أضيفت بعض القواعد قبل الخطأ: '+_err(e)+'. راجع التعليقات NOVA:RAW.',bad:true);await _load();}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _applyWanProtection() async{
    if(_client==null||_busy)return;
    if(_hasTag(_raw,'NOVA:RAW:WAN:')){_toast('قواعد حماية WAN موجودة مسبقاً.',bad:true);return;}
    if(!await _confirm('إغلاق DNS وWinBox من WAN؟','ستُحجب طلبات DNS إلى الراوتر ومنافذ WinBox من WAN. يُستثنى Trusted_Admin. تأكد أن الإدارة عن بعد تعمل عبر VPN أو قائمة موثوقة قبل المتابعة.'))return;
    setState(()=>_busy=true);
    try{
      for(final protocol in const ['tcp','udp']){
        await _add('/ip/firewall/raw/add',{'chain':'prerouting','in-interface-list':'WAN','dst-address-type':'local','protocol':protocol,'dst-port':'53','src-address-list':'!Trusted_Admin','action':'drop','place-before':'0','comment':'NOVA:RAW:WAN:DNS:'+protocol});
      }
      await _add('/ip/firewall/raw/add',{'chain':'prerouting','in-interface-list':'WAN','dst-address-type':'local','protocol':'tcp','dst-port':'8291','src-address-list':'!Trusted_Admin','action':'drop','place-before':'0','comment':'NOVA:RAW:WAN:WINBOX'});
      _toast('تم حجب DNS وWinBox إلى عنوان الراوتر من WAN لغير Trusted_Admin.');
      await _load();
    }catch(e){_toast('تعذر إكمال الحماية: '+_err(e),bad:true);await _load();}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _applyP2p() async{
    if(_client==null||_busy)return;
    if(_hasTag(_raw,'NOVA:RAW:P2P:')){_toast('قواعد P2P موجودة مسبقاً.',bad:true);return;}
    if(!await _confirm('حجب منافذ P2P الشائعة؟','يحجب هذا فقط منافذ TCP/UDP المعروفة 6881–6999 من WAN. لا يستطيع هذا كشف كل Torrent أو Spam الذي يستخدم منافذ عشوائية أو مشفّرة.'))return;
    setState(()=>_busy=true);
    try{
      for(final protocol in const ['tcp','udp']){
        await _add('/ip/firewall/raw/add',{'chain':'prerouting','in-interface-list':'WAN','protocol':protocol,'dst-port':'6881-6999','action':'drop','place-before':'0','comment':'NOVA:RAW:P2P:'+protocol});
      }
      _toast('تم حجب نطاق منافذ P2P الشائعة على WAN.');
      await _load();
    }catch(e){_toast(_err(e),bad:true);await _load();}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _applyQos() async{
    if(_client==null||_busy)return;
    final up=int.tryParse(_upload.text.trim()),down=int.tryParse(_download.text.trim());
    if(up==null||down==null||up<1||down<1||up>10000||down>10000){_toast('أدخل سرعات رفع وتنزيل من 1 إلى 10000 Mbps.',bad:true);return;}
    if(_hasTag(_mangle,'NOVA:QOS:')||_hasTag(_trees,'NOVA:QOS:')){_toast('قواعد QoS موجودة مسبقاً. احذف قواعد NOVA:QOS أولاً لتجنب الازدواج.',bad:true);return;}
    if(!await _confirm('تفعيل أولوية Ping وDNS؟','ستُنشأ علامات حزم وقوائم PCQ بحدود رفع '+up+'M وتنزيل '+down+'M. أدخل السرعات الفعلية للخطوط؛ تشكيل غير مناسب قد يقلل الأداء. الأولوية تكون فعالة عند ازدحام الطوابير فقط.'))return;
    setState(()=>_busy=true);
    try{
      await _add('/queue/type/add',{'name':'NOVA-PCQ-UP','kind':'pcq','pcq-classifier':'src-address','comment':'NOVA:QOS:TYPE:UP'});
      await _add('/queue/type/add',{'name':'NOVA-PCQ-DOWN','kind':'pcq','pcq-classifier':'dst-address','comment':'NOVA:QOS:TYPE:DOWN'});
      for(final protocol in const ['icmp','udp','tcp']){
        final extra=protocol=='icmp'?<String,String>{}:protocol=='udp'?<String,String>{'dst-port':'53,3478-3481,3074,27000-27100'}:<String,String>{'dst-port':'53'};
        await _add('/ip/firewall/mangle/add',{'chain':'prerouting','protocol':protocol,...extra,'action':'mark-packet','new-packet-mark':'NOVA-PRIO-DOWN','passthrough':'no','comment':'NOVA:QOS:DOWN:'+protocol});
        await _add('/ip/firewall/mangle/add',{'chain':'postrouting','protocol':protocol,...extra,'action':'mark-packet','new-packet-mark':'NOVA-PRIO-UP','passthrough':'no','comment':'NOVA:QOS:UP:'+protocol});
      }
      await _add('/ip/firewall/mangle/add',{'chain':'output','protocol':'icmp','action':'mark-packet','new-packet-mark':'NOVA-PRIO-UP','passthrough':'no','comment':'NOVA:QOS:ROUTER-ICMP'});
      await _add('/queue/tree/add',{'name':'NOVA-QOS-Upload-Priority','parent':'global-out','packet-mark':'NOVA-PRIO-UP','queue':'NOVA-PCQ-UP','priority':'1','max-limit':up.toString()+'M','comment':'NOVA:QOS:TREE:UP'});
      await _add('/queue/tree/add',{'name':'NOVA-QOS-Download-Priority','parent':'global-in','packet-mark':'NOVA-PRIO-DOWN','queue':'NOVA-PCQ-DOWN','priority':'1','max-limit':down.toString()+'M','comment':'NOVA:QOS:TREE:DOWN'});
      _toast('تم إنشاء أولوية Ping/DNS وPCQ. تأكد من توافق السرعات مع PCC وQueue الحالية.');
      await _load();
    }catch(e){_toast('لم تكتمل كل قواعد QoS: '+_err(e)+'. افحص NOVA:QOS وأزل القواعد الجزئية قبل المحاولة مجدداً.',bad:true);await _load();}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _removeOwned() async{
    final c=_client;if(c==null||_busy)return;
    if(!await _confirm('حذف قواعد NOVA؟','ستُحذف القواعد والطوابير وأنواع PCQ التي تحمل تعليقات NOVA:RAW أو NOVA:QOS فقط.'))return;
    setState(()=>_busy=true);
    try{
      final data=await Future.wait([c.command('/ip/firewall/raw/print'),c.command('/ip/firewall/filter/print'),c.command('/ip/firewall/mangle/print'),c.command('/queue/tree/print'),c.command('/queue/type/print')]);
      const paths=['/ip/firewall/raw/remove','/ip/firewall/filter/remove','/ip/firewall/mangle/remove','/queue/tree/remove','/queue/type/remove'];
      for(var n=0;n<data.length;n++){
        for(final row in data[n]){
          final comment=row['comment']??'',name=row['name']??'';
          final owned=comment.startsWith('NOVA:RAW:')||comment.startsWith('NOVA:QOS:')||name.startsWith('NOVA-QOS-')||name.startsWith('NOVA-PCQ-');
          final id=row['.id']??row['id'];
          if(owned&&id!=null)await c.command(paths[n],args:{'.id':id});
        }
      }
      _toast('حُذفت قواعد RAW/QoS التي يديرها NOVA.');await _load();
    }catch(e){_toast(_err(e),bad:true);await _load();}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Widget _card(String title,String desc,IconData icon,Widget action)=>Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:_panel,borderRadius:BorderRadius.circular(17),border:Border.all(color:Colors.white.withOpacity(.07))),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    Row(children:[Icon(icon,color:_accent),const SizedBox(width:9),Expanded(child:Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w800,fontSize:14)))]),
    const SizedBox(height:9),Text(desc,style:const TextStyle(color:Colors.white70,fontSize:11,height:1.5)),const SizedBox(height:12),action]));
  Widget _button(String title,VoidCallback? callback,{bool danger=false})=>SizedBox(height:46,child:FilledButton.icon(onPressed:callback,style:FilledButton.styleFrom(backgroundColor:danger?_red:_accent),icon:const Icon(Icons.bolt),label:Text(title,textAlign:TextAlign.center)));
  @override Widget build(BuildContext context){
    if(_client==null)return Scaffold(backgroundColor:_bg,appBar:AppBar(title:const Text('RAW Security & QoS')),body:const Center(child:Text('اتصل بالراوتر أولاً.')));
    final rawCount=_raw.where((r)=>(r['comment']??'').startsWith('NOVA:RAW:')).length;
    final qosCount=_mangle.where((r)=>(r['comment']??'').startsWith('NOVA:QOS:')).length+_trees.where((r)=>(r['comment']??'').startsWith('NOVA:QOS:')).length;
    return Scaffold(backgroundColor:_bg,appBar:AppBar(backgroundColor:_bg,foregroundColor:Colors.white,title:const Text('درع RAW وتسريع Ping / DNS'),actions:[IconButton(onPressed:_busy?null:_load,icon:const Icon(Icons.refresh,color:_accent))]),body:_loading?const Center(child:CircularProgressIndicator(color:_accent)):ListView(padding:const EdgeInsets.all(14),children:[
      if(_error!=null)_card('خطأ اتصال',_error!,Icons.error_outline,const SizedBox.shrink()),
      _card('درع SYN / ICMP Flood والماسحات','قواعد محددة إلى عنوان الراوتر من WAN مع حدود أولية، وقوائم ديناميكية للـ SYN كثيف الاتصالات وPort Scanners. عدد قواعد NOVA الحالية: '+rawCount.toString(),Icons.shield_outlined,_button(_hasTag(_raw,'NOVA:RAW:SHIELD:')?'درع Flood موجود':'تفعيل درع الحماية RAW بضغطة زر',_busy||_hasTag(_raw,'NOVA:RAW:SHIELD:')?null:_applyShield)),
      _card('حماية DNS وWinBox من WAN','حجب TCP/UDP 53 وWinBox 8291 المتجهة إلى الراوتر من WAN، مع استثناء Trusted_Admin. تحقق من مسار الإدارة قبل التفعيل.',Icons.lock_outline,_button(_hasTag(_raw,'NOVA:RAW:WAN:')?'قواعد WAN موجودة':'إغلاق DNS وWinBox من WAN',_busy||_hasTag(_raw,'NOVA:RAW:WAN:')?null:_applyWanProtection)),
      _card('حجب نطاق منافذ P2P الشائعة','حجب TCP/UDP 6881–6999 فقط. لا يكشف هذا كل التورنت أو السبام، خصوصاً على منافذ عشوائية أو اتصالات مشفرة.',Icons.block,_button(_hasTag(_raw,'NOVA:RAW:P2P:')?'قواعد P2P موجودة':'حجب منافذ P2P من WAN',_busy||_hasTag(_raw,'NOVA:RAW:P2P:')?null:_applyP2p)),
      _card('أولوية Ping وDNS والألعاب الصغيرة','علامات ICMP وDNS وبعض منافذ الألعاب الشائعة إلى طوابير PCQ بأولوية 1. أدخل سقف السرعة أقل بقليل من السعة الفعلية كي يطبق التشكيل عند الازدحام.',Icons.speed,
        Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Row(children:[Expanded(child:TextField(controller:_upload,keyboardType:TextInputType.number,inputFormatters:[FilteringTextInputFormatter.digitsOnly],decoration:const InputDecoration(labelText:'رفع Mbps'))),const SizedBox(width:10),Expanded(child:TextField(controller:_download,keyboardType:TextInputType.number,inputFormatters:[FilteringTextInputFormatter.digitsOnly],decoration:const InputDecoration(labelText:'تنزيل Mbps')))]),
          const SizedBox(height:10),_button(qosCount>0?'QoS موجودة بالفعل ('+qosCount.toString()+')':'تفعيل Ping & DNS Priority QoS',_busy||qosCount>0?null:_applyQos)
        ])),
      _card('حالة وإزالة قواعد NOVA','RAW: '+rawCount.toString()+' • Mangle/Queue QoS: '+qosCount.toString()+'. الحذف يقتصر على التعليقات والأسماء الخاصة بالتطبيق.',Icons.cleaning_services_outlined,_button('حذف قواعد NOVA RAW/QoS',_busy?null:_removeOwned,danger:true)),
      const SizedBox(height:8),const Text('تنبيه: قواعد RAW تتنفذ قبل Connection Tracking. لا تضف قواعد SYN أو ICMP عامة دون تحديد العتبة والوجهة. تُنشأ القواعد بعلامات NOVA لتمييزها ويمكن حذفها من الزر أعلاه.',style:TextStyle(color:_muted,fontSize:10,height:1.5))
    ]));
  }
}
