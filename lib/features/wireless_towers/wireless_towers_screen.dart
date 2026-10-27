import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/providers/router_providers.dart';
import 'wireless_towers_service.dart';

const _bg=Color(0xFF080B12),_panel=Color(0xFF111722),_accent=Color(0xFF8B7CFF),_muted=Color(0xFF8D9AB0),_green=Color(0xFF43D9A3),_red=Color(0xFFFF657A);
class WirelessTowersScreen extends ConsumerStatefulWidget {
  const WirelessTowersScreen({super.key});
  @override ConsumerState<WirelessTowersScreen> createState()=>_WirelessTowersScreenState();
}
class _WirelessTowersScreenState extends ConsumerState<WirelessTowersScreen> {
  WirelessTowersService? _service;
  List<TowerDevice> _devices=[];
  List<Map<String,String>> _stations=[],_wireless=[],_poe=[];
  bool _loading=true,_busy=false;
  String? _error;
  Timer? _timer;
  final _external=TextEditingController();
  @override void initState(){super.initState();final c=ref.read(activeRouterClientProvider);if(c==null){_loading=false;_error='اتصل بالراوتر أولاً.';}else{_service=WirelessTowersService(c);unawaited(_refresh());_timer=Timer.periodic(const Duration(seconds:30),(_){if(!_busy)unawaited(_refresh(silent:true));});}}
  @override void dispose(){_timer?.cancel();_external.dispose();super.dispose();}
  String _err(Object e)=>e.toString().replaceFirst('RouterOsException: ','');
  void _toast(String s,{bool bad=false}){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s),backgroundColor:bad?_red:const Color(0xFF1A443C),behavior:SnackBarBehavior.floating));}
  Future<void> _refresh({bool silent=false}) async{
    final s=_service;if(s==null)return;if(!silent&&mounted)setState(()=>_loading=true);
    List<Map<String,String>> w=[],st=[],p=[];List<TowerDevice>d=[];final errors=<String>[];
    try{w=await s.wirelessInterfaces();}catch(e){errors.add('Wireless: '+_err(e));}
    try{st=await s.registrationTable();}catch(e){errors.add('Registration: '+_err(e));}
    try{d=await s.discoverDevices(maxPings:16);}catch(e){errors.add('Discovery/Ping: '+_err(e));}
    try{p=await s.ethernetPoePorts();}catch(e){errors.add('PoE: '+_err(e));}
    if(!mounted)return;
    setState((){_wireless=w;_stations=st;_devices=d;_poe=p;_loading=false;_error=errors.isEmpty?null:errors.join('\n');});
  }
  Future<void> _openDevice(TowerDevice device) async{
    final ip=device.ipAddress;if(ip==null||ip.isEmpty){_toast('لا يوجد عنوان IP لهذا الجهاز.',bad:true);return;}
    final ext=_external.text.trim();
    final choice=await showModalBottomSheet<String>(context:context,backgroundColor:_panel,useSafeArea:true,
      shape:const RoundedRectangleBorder(borderRadius:BorderRadius.vertical(top:Radius.circular(22))),
      builder:(ctx)=>Padding(padding:const EdgeInsets.all(18),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Text(device.displayName,style:const TextStyle(color:Colors.white,fontSize:16,fontWeight:FontWeight.w800)),
        const SizedBox(height:6),Text('IP المحلي: '+ip,style:const TextStyle(color:_muted)),
        const SizedBox(height:12),FilledButton.icon(onPressed:()=>Navigator.pop(ctx,'local'),icon:const Icon(Icons.lan),label:const Text('فتح صفحة الجهاز محلياً')),
        const SizedBox(height:8),OutlinedButton.icon(onPressed:ext.isEmpty?null:()=>Navigator.pop(ctx,'external'),icon:const Icon(Icons.public),label:Text(ext.isEmpty?'أدخل عنوان الوصول الخارجي أدناه أولاً':'فتح عبر Port Forwarding الخارجي')),
        if(ext.isNotEmpty)SelectableText(ext,style:const TextStyle(color:_green))
      ])));
    if(choice==null)return;final raw=choice=='local'?'http://'+ip:ext;final uri=Uri.tryParse(raw.contains('://')?raw:'http://'+raw);
    if(uri==null||!const ['http','https'].contains(uri.scheme)||uri.host.isEmpty){_toast('عنوان الويب غير صالح.',bad:true);return;}
    try{final opened=await launchUrl(uri,mode:LaunchMode.externalApplication);if(!opened)_toast('تعذر فتح المتصفح. تحقق من الرابط.',bad:true);}catch(e){_toast(_err(e),bad:true);}
  }
  Future<void> _cyclePoe(Map<String,String> row) async{
    final s=_service,id=row['.id']??row['id'],name=row['interface']??row['name']??'منفذ PoE';if(s==null||id==null||_busy)return;
    final yes=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(backgroundColor:_panel,title:const Text('إعادة تشغيل الصحن كهربائياً؟'),content:Text('سيتم فصل تغذية '+name+' لمدة 5 ثوانٍ وقد ينقطع اتصال المشتركين.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),style:FilledButton.styleFrom(backgroundColor:_red),child:const Text('فصل وإعادة التشغيل'))]))??false;
    if(!yes)return;setState(()=>_busy=true);try{await s.cyclePoe(id:id);_toast('اكتملت إعادة تشغيل PoE: '+name);await _refresh(silent:true);}catch(e){_toast(_err(e),bad:true);}finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _setPoe(Map<String,String> row,String mode) async{final s=_service,id=row['.id']??row['id'];if(s==null||id==null||_busy)return;setState(()=>_busy=true);try{await s.setPoeMode(id:id,mode:mode);_toast('تم ضبط PoE إلى '+mode);await _refresh(silent:true);}catch(e){_toast(_err(e),bad:true);}finally{if(mounted)setState(()=>_busy=false);}}
  Future<void> _editWireless(Map<String,String> row) async{
    final s=_service,id=row['.id']??row['id'];if(s==null||id==null||_busy)return;
    final ssid=TextEditingController(text:row['ssid']??''),freq=TextEditingController(text:row['frequency']??'');
    const widths=['5MHz','10MHz','20MHz','20/40MHz','40MHz','10/20/40MHz','20/40/80MHz','20/40/80/160MHz'];var width=row['channel-width']??'20/40MHz';if(!widths.contains(width))width='20MHz';
    final form=GlobalKey<FormState>();
    final save=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setDialog)=>AlertDialog(backgroundColor:_panel,title:Text('إعداد '+(row['name']??'Wireless')),
      content:Form(key:form,child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextFormField(controller:ssid,decoration:const InputDecoration(labelText:'SSID'),validator:(v)=>(v??'').trim().isEmpty?'أدخل SSID':null),
        TextFormField(controller:freq,keyboardType:TextInputType.number,inputFormatters:[FilteringTextInputFormatter.digitsOnly],decoration:const InputDecoration(labelText:'Frequency (MHz)')),
        const SizedBox(height:8),DropdownButtonFormField<String>(value:width,dropdownColor:_panel,decoration:const InputDecoration(labelText:'Channel Width'),items:widths.map((v)=>DropdownMenuItem(value:v,child:Text(v))).toList(),onChanged:(v)=>setDialog(()=>width=v??width))
      ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,form.currentState?.validate()==true),child:const Text('حفظ'))])));
    if(save==true){setState(()=>_busy=true);try{await s.updateWirelessInterface(id:id,ssid:ssid.text.trim(),frequency:freq.text.trim().isEmpty?null:freq.text.trim(),channelWidth:width);_toast('تم تحديث اللاسلكي.');await _refresh(silent:true);}catch(e){_toast(_err(e),bad:true);}finally{if(mounted)setState(()=>_busy=false);}}ssid.dispose();freq.dispose();
  }
  Widget _card(String t,Widget child)=>Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(13),decoration:BoxDecoration(color:_panel,borderRadius:BorderRadius.circular(17),border:Border.all(color:Colors.white.withOpacity(.07))),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[Text(t,style:const TextStyle(color:Colors.white,fontSize:14,fontWeight:FontWeight.w800)),const SizedBox(height:10),child]));
  InputDecoration _dec(String t,{String? hint})=>InputDecoration(labelText:t,hintText:hint,labelStyle:const TextStyle(color:_muted,fontSize:12),filled:true,fillColor:const Color(0xFF0B1019),border:OutlineInputBorder(borderRadius:BorderRadius.circular(12)));
  String _signal(Map<String,String> r){final v=r['signal-strength']??r['signal-strength-ch0']??'—';final m=RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(v);return m==null?v:m.group(0)!+' dBm';}
  double? _signalNum(Map<String,String> r){final v=r['signal-strength']??r['signal-strength-ch0']??'';final m=RegExp(r'-?[0-9]+(?:\.[0-9]+)?').firstMatch(v);return m==null?null:double.tryParse(m.group(0)!);}
  String _rate(String? v)=>(v==null||v.isEmpty)?'—':v;
  String _ccq(String? v)=>(v==null||v.isEmpty)?'—':(v.contains('%')?v:v+'%');
  @override Widget build(BuildContext context){
    if(_service==null||ref.watch(activeRouterClientProvider)==null)return Scaffold(backgroundColor:_bg,appBar:AppBar(title:const Text('الصحون والأبراج')),body:const Center(child:Text('اتصل بالراوتر أولاً.')));
    return DefaultTabController(length:3,child:Scaffold(backgroundColor:_bg,appBar:AppBar(backgroundColor:_bg,foregroundColor:Colors.white,title:const Text('الصحون والأبراج اللاسلكية',style:TextStyle(fontSize:17,fontWeight:FontWeight.w800)),actions:[IconButton(onPressed:_busy?null:()=>_refresh(),icon:const Icon(Icons.refresh,color:_accent))],bottom:const TabBar(isScrollable:true,indicatorColor:_accent,tabs:[Tab(icon:Icon(Icons.cell_tower_rounded),text:'الصحون والأبراج'),Tab(icon:Icon(Icons.wifi_tethering_rounded),text:'المتصلون لاسلكياً'),Tab(icon:Icon(Icons.settings_input_antenna_rounded),text:'الترددات')])),body:Column(children:[
      if(_error!=null)Container(width:double.infinity,margin:const EdgeInsets.fromLTRB(12,10,12,0),padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:_red.withOpacity(.1),borderRadius:BorderRadius.circular(12)),child:Text(_error!,style:const TextStyle(color:_red,fontSize:11))),
      if(_busy)const LinearProgressIndicator(color:_accent,minHeight:2),
      Expanded(child:_loading?const Center(child:CircularProgressIndicator(color:_accent)):TabBarView(children:[_devicesTab(),_stationsTab(),_wirelessTab()]))
    ])));
  }
  Widget _devicesTab()=>ListView(padding:const EdgeInsets.all(12),children:[
    _card('أجهزة الجوار وARP',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[const Text('يجمع التطبيق الجيران وجدول ARP ويختبر حتى 16 جهازاً لكل تحديث عبر Ping من الراوتر.',style:TextStyle(color:Colors.white70,fontSize:11,height:1.5)),const SizedBox(height:8),TextField(controller:_external,textDirection:TextDirection.ltr,autocorrect:false,decoration:_dec('عنوان Port Forwarding الخارجي (اختياري)',hint:'https://dish.example.net:18443')),const SizedBox(height:8),Text('الأجهزة المكتشفة: '+_devices.length.toString(),style:const TextStyle(color:_muted,fontSize:11))])),
    if(_devices.isEmpty)_card('لا توجد أجهزة مكتشفة',const Text('راجع جدول ARP والجيران ثم حدّث الشاشة.',style:TextStyle(color:_muted))) else ..._devices.map((d){
      final ping=d.ping;final good=ping!=null&&ping.isStable;final color=ping==null?_muted:good?_green:_red;final ports=_poe.where((p)=>(p['interface']??p['name'])==d.interfaceName).toList();
      return _card(d.displayName,Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        SelectableText((d.ipAddress??'لا يوجد IP')+' • '+(d.macAddress??'MAC غير معروف'),style:const TextStyle(color:Colors.white70,fontSize:11)),
        const SizedBox(height:5),Text((d.interfaceName.isEmpty?'واجهة غير معروفة':d.interfaceName)+' • '+d.source+' • '+d.platform,style:const TextStyle(color:_muted,fontSize:10)),
        const SizedBox(height:7),Row(children:[Icon(ping==null?Icons.help_outline:good?Icons.check_circle_outline:Icons.warning_amber_rounded,color:color,size:17),const SizedBox(width:6),Expanded(child:Text(ping==null?'Ping غير متاح':'Latency: '+(ping.latencyMs?.toStringAsFixed(1)??'timeout')+' ms • Loss: '+ping.packetLossPercent.toStringAsFixed(0)+'%',style:TextStyle(color:color,fontSize:11,fontWeight:FontWeight.w700))),IconButton(tooltip:'فتح واجهة الجهاز',onPressed:_busy?null:()=>_openDevice(d),icon:const Icon(Icons.open_in_browser,color:_accent))]),
        if(ports.isNotEmpty)...[const Divider(color:Color(0xFF283142)),...ports.map((p)=>Row(children:[Expanded(child:Text('PoE '+(p['interface']??p['name']??'')+' • '+(p['poe-out-power']??'—')+' W • '+(p['poe-out']??'—'),style:const TextStyle(color:_muted,fontSize:10))),IconButton(tooltip:'إعادة تشغيل الصحن كهربائياً (PoE Power Cycle)',onPressed:_busy?null:()=>_cyclePoe(p),icon:const Icon(Icons.restart_alt,color:_red))]))]
      ]));
    }),
    if(_poe.isNotEmpty)_card('منافذ PoE',Column(children:_poe.map((p)=>ListTile(contentPadding:EdgeInsets.zero,title:Text(p['interface']??p['name']??'Ethernet',style:const TextStyle(color:Colors.white,fontSize:12)),subtitle:Text('القدرة: '+(p['poe-out-power']??'—')+' W • الحالة: '+(p['poe-out-status']??p['poe-out']??'—'),style:const TextStyle(color:_muted,fontSize:10)),trailing:PopupMenuButton<String>(enabled:!_busy,onSelected:(v)=>_setPoe(p,v),icon:const Icon(Icons.power_settings_new,color:_accent),itemBuilder:(_)=>const [PopupMenuItem(value:'auto-on',child:Text('Auto On')),PopupMenuItem(value:'forced-on',child:Text('Forced On')),PopupMenuItem(value:'off',child:Text('Off'))]))).toList()))
  ]);
  Widget _stationsTab()=>ListView(padding:const EdgeInsets.all(12),children:[
    _card('Wireless Registration Table',Text('المتصلون الآن: '+_stations.length.toString(),style:const TextStyle(color:_muted,fontSize:12))),
    if(_stations.isEmpty)_card('لا توجد محطات مسجلة',const Text('قد لا تكون حزمة wireless مثبتة أو لا توجد محطات متصلة.',style:TextStyle(color:_muted,fontSize:12))) else ..._stations.map((r){
      final n=_signalNum(r);final weak=n!=null&&n< -75;final color=weak?_red:_green;
      return _card(r['mac-address']??r['radio-name']??r['.id']??'Station',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Text('Interface: '+(r['interface']??'—')+' • Signal: '+_signal(r),style:TextStyle(color:color,fontSize:12,fontWeight:FontWeight.w800)),
        const SizedBox(height:5),Text('TX CCQ: '+_ccq(r['tx-ccq'])+' • RX CCQ: '+_ccq(r['rx-ccq']),style:const TextStyle(color:Colors.white70,fontSize:11)),
        const SizedBox(height:4),Text('TX Rate: '+_rate(r['tx-rate'])+'\nRX Rate: '+_rate(r['rx-rate']),style:const TextStyle(color:_muted,fontSize:11,height:1.5)),
        if(weak)const Padding(padding:EdgeInsets.only(top:5),child:Text('إشارة ضعيفة: أضعف من -75 dBm؛ افحص المحاذاة والتداخل والكابل.',style:TextStyle(color:_red,fontSize:11)))
      ]));
    })
  ]);
  Widget _wirelessTab()=>ListView(padding:const EdgeInsets.all(12),children:[
    _card('واجهات اللاسلكي',const Text('تغيير التردد قد يقطع الاتصال مؤقتاً. أجهزة RouterOS الحديثة قد تستخدم wifi أو wifiwave2 بدلاً من wireless.',style:TextStyle(color:Colors.white70,fontSize:11,height:1.5))),
    if(_wireless.isEmpty)_card('لا توجد واجهات wireless',const Text('تحقق من توافق الجهاز وحزمة اللاسلكي في RouterOS.',style:TextStyle(color:_muted,fontSize:12))) else ..._wireless.map((r)=>_card(r['name']??'Wireless',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Text('SSID: '+(r['ssid']??'—'),style:const TextStyle(color:Colors.white70,fontSize:12)),const SizedBox(height:4),Text('Frequency: '+(r['frequency']??'—')+' MHz • Channel Width: '+(r['channel-width']??'—'),style:const TextStyle(color:_muted,fontSize:11)),const SizedBox(height:8),
      Align(alignment:Alignment.centerRight,child:OutlinedButton.icon(onPressed:_busy?null:()=>_editWireless(r),icon:const Icon(Icons.tune),label:const Text('تعديل SSID والتردد وعرض القناة')))
    ])))
  ]);
}
