import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';

const _bg=Color(0xFF080B12),_panel=Color(0xFF111722),_accent=Color(0xFF8B7CFF),_muted=Color(0xFF8D9AB0),_green=Color(0xFF43D9A3),_red=Color(0xFFFF657A);

class TelegramAlertsScreen extends ConsumerStatefulWidget {
  const TelegramAlertsScreen({super.key});
  @override ConsumerState<TelegramAlertsScreen> createState()=>_TelegramAlertsScreenState();
}
class _TelegramAlertsScreenState extends ConsumerState<TelegramAlertsScreen> {
  RouterOsClient? get _client=>ref.read(activeRouterClientProvider);
  final _token=TextEditingController(),_chat=TextEditingController(),_wanHosts=TextEditingController(text:'1.1.1.1,8.8.8.8'),_towerHosts=TextEditingController();
  bool _wanAlerts=true,_towerAlerts=false,_securityAlerts=true,_busy=false,_loading=true,_hideToken=true;
  List<Map<String,String>> _scripts=[],_schedulers=[],_netwatch=[];
  String? _error;
  @override void initState(){super.initState();_load();}
  @override void dispose(){for(final c in [_token,_chat,_wanHosts,_towerHosts]){c.dispose();}super.dispose();}
  String _err(Object e)=>e.toString().replaceFirst('RouterOsException: ','');
  void _toast(String s,{bool bad=false}){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s),backgroundColor:bad?_red:const Color(0xFF1A443C),behavior:SnackBarBehavior.floating));}
  Future<void> _load() async{
    final c=_client;if(c==null){if(mounted)setState(()=>_loading=false);return;}
    try{
      final r=await Future.wait([c.command('/system/script/print'),c.command('/system/scheduler/print'),c.command('/tool/netwatch/print')]);
      if(!mounted)return;
      setState((){_scripts=r[0].where((x)=>(x['comment']??'').startsWith('NOVA:TELEGRAM:')).toList();_schedulers=r[1].where((x)=>(x['comment']??'').startsWith('NOVA:TELEGRAM:')).toList();_netwatch=r[2].where((x)=>(x['comment']??'').startsWith('NOVA:TELEGRAM:')).toList();_loading=false;_error=null;});
    }catch(e){if(mounted)setState((){_loading=false;_error=_err(e);});}
  }
  bool _validHosts(String raw)=>raw.trim().isEmpty||raw.split(',').every((host)=>RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$').hasMatch(host.trim())&&!host.trim().contains('..'));
  List<String> _hosts(String raw)=>raw.split(',').map((v)=>v.trim()).where((v)=>v.isNotEmpty).toSet().toList();
  String _encoded(String text)=>Uri.encodeComponent(text);
  String _senderSource(String token,String chat)=>':global NOVA_TG_TEXT; '
      ':if ([:len \$NOVA_TG_TEXT] = 0) do={ :set NOVA_TG_TEXT "NOVA%20router%20alert"; }; '
      ':local token "'+token+'"; :local chat "'+chat+'"; '
      ':local url ("https://api.telegram.org/bot" . \$token . "/sendMessage?chat_id=" . \$chat . "&text=" . \$NOVA_TG_TEXT); '
      ':do { /tool/fetch url=\$url keep-result=no check-certificate=yes; } on-error={ :log error "NOVA Telegram delivery failed"; }; '
      ':set NOVA_TG_TEXT "";';
  String _healthSource()=>':local cpu [:tonum [/system/resource get cpu-load]]; '
      ':local temp 0; :do { :set temp [:tonum [/system/health get [find where name="cpu-temperature"] value]]; } on-error={ :set temp 0; }; '
      ':global NOVA_TG_HOT_SENT; '
      ':if ((\$cpu > 85) || (\$temp > 85)) do={ :if (\$NOVA_TG_HOT_SENT != true) do={ '
      ':global NOVA_TG_TEXT; :set NOVA_TG_TEXT "NOVA%20alert%3A%20CPU%20or%20temperature%20above%2085%25"; '
      '/system/script/run NOVA-Telegram-Send; :set NOVA_TG_HOT_SENT true; } } else={ '
      ':if ((\$cpu < 80) && (\$temp < 80)) do={ :set NOVA_TG_HOT_SENT false; } };';
  String _loginSource()=>':global NOVA_TG_LAST_LOG_ID; :local entries [/log find where topics~"account"]; '
      ':if ([:len \$entries] > 0) do={ :local last [:pick \$entries ([:len \$entries] - 1)]; '
      ':if ([:typeof \$NOVA_TG_LAST_LOG_ID] = "nothing") do={ :set NOVA_TG_LAST_LOG_ID \$last; } else={ '
      ':if (\$last != \$NOVA_TG_LAST_LOG_ID) do={ :set NOVA_TG_LAST_LOG_ID \$last; '
      ':global NOVA_TG_TEXT; :set NOVA_TG_TEXT "NOVA%20security%20alert%3A%20router%20account%20event"; '
      '/system/script/run NOVA-Telegram-Send; } } };';
  String _netwatchScript(String message)=>':global NOVA_TG_TEXT; :set NOVA_TG_TEXT "'+_encoded(message)+'"; /system/script/run NOVA-Telegram-Send;';
  String _commentName(String prefix,String value)=>prefix+value.replaceAll(RegExp('[^A-Za-z0-9_.-]'),'_');

  Future<void> _upsertScript(String name,String source,String comment) async{
    final c=_client!;
    final rows=await c.command('/system/script/print');
    final found=rows.where((r)=>r['name']==name).toList();
    if(found.isEmpty){await c.command('/system/script/add',args:{'name':name,'source':source,'policy':'read,write,policy,test,sensitive','comment':comment});return;}
    final row=found.first;final id=row['.id']??row['id'];
    if(id==null||!(row['comment']??'').startsWith('NOVA:TELEGRAM:'))throw StateError('يوجد Script باسم $name ليس تابعاً لـ NOVA؛ لن يتم استبداله.');
    await c.command('/system/script/set',args:{'.id':id,'source':source,'policy':'read,write,policy,test,sensitive','comment':comment});
  }
  Future<void> _upsertScheduler(String name,String script,String comment) async{
    final c=_client!;final rows=await c.command('/system/scheduler/print');final found=rows.where((r)=>r['name']==name).toList();
    final args=<String,String>{'name':name,'start-time':'startup','interval':'1m','on-event':'/system/script/run '+script,'policy':'read,write,policy,test,sensitive','disabled':'no','comment':comment};
    if(found.isEmpty){await c.command('/system/scheduler/add',args:args);return;}
    final row=found.first;final id=row['.id']??row['id'];
    if(id==null||!(row['comment']??'').startsWith('NOVA:TELEGRAM:'))throw StateError('يوجد Scheduler باسم $name ليس تابعاً لـ NOVA؛ لن يتم استبداله.');
    args.remove('name');await c.command('/system/scheduler/set',args:{'.id':id,...args});
  }
  Future<void> _upsertNetwatch(String group,String host,String label) async{
    final c=_client!;final comment=_commentName('NOVA:TELEGRAM:'+group+':',host);
    final rows=await c.command('/tool/netwatch/print');final found=rows.where((r)=>(r['comment']??'')==comment).toList();
    final up=_netwatchScript('NOVA $label $host restored');
    final down=_netwatchScript('NOVA ALERT $label $host DOWN');
    final args=<String,String>{'host':host,'interval':'30s','timeout':'3s','up-script':up,'down-script':down,'disabled':'no','comment':comment};
    if(found.isEmpty){await c.command('/tool/netwatch/add',args:args);return;}
    final row=found.first;final id=row['.id']??row['id'];if(id==null)throw StateError('تعذر تحديث Netwatch للعنوان $host.');
    await c.command('/tool/netwatch/set',args:{'.id':id,...args});
  }
  Future<void> _install() async{
    final c=_client;if(c==null||_busy)return;
    final token=_token.text.trim(),chat=_chat.text.trim();
    if(!RegExp(r'^[0-9]{5,}:[A-Za-z0-9_-]{20,}$').hasMatch(token)){_toast('Bot Token غير صالح. راجعه من BotFather.',bad:true);return;}
    if(!RegExp(r'^-?[0-9]+$|^@[A-Za-z0-9_]{5,}$').hasMatch(chat)){_toast('Chat ID يجب أن يكون رقماً أو اسم قناة يبدأ بـ @.',bad:true);return;}
    final wan=_hosts(_wanHosts.text),towers=_hosts(_towerHosts.text);
    if(_wanAlerts&&wan.isEmpty){_toast('أدخل هدف Ping واحداً على الأقل لمراقبة الإنترنت.',bad:true);return;}
    if(_towerAlerts&&towers.isEmpty){_toast('أدخل IP أو أسماء الأجهزة الرئيسية لمراقبتها.',bad:true);return;}
    if((_wanAlerts&&!_validHosts(_wanHosts.text))||(_towerAlerts&&!_validHosts(_towerHosts.text))){_toast('أحد العناوين يحتوي أحرفاً غير مسموحة.',bad:true);return;}
    if(!_wanAlerts&&!_towerAlerts&&!_securityAlerts){_toast('اختر نوع تنبيه واحداً على الأقل.',bad:true);return;}
    if (!(await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(backgroundColor:_panel,title:const Text('تفعيل تنبيهات الراوتر؟'),content:const Text('سيحفظ الراوتر Bot Token داخل Script، وينشئ Scheduler وNetwatch. قيّد صلاحيات الوصول إلى System Scripts؛ لا تشارك هذا الرمز.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('تفعيل'))])) ?? false)) return;
    setState(()=>_busy=true);
    try{
      await _upsertScript('NOVA-Telegram-Send',_senderSource(token,chat),'NOVA:TELEGRAM:SENDER');
      if(_securityAlerts){
        await _upsertScript('NOVA-Telegram-Health',_healthSource(),'NOVA:TELEGRAM:HEALTH');
        await _upsertScript('NOVA-Telegram-LoginWatch',_loginSource(),'NOVA:TELEGRAM:LOGIN');
        await _upsertScheduler('NOVA-Telegram-Health','NOVA-Telegram-Health','NOVA:TELEGRAM:HEALTH');
        await _upsertScheduler('NOVA-Telegram-LoginWatch','NOVA-Telegram-LoginWatch','NOVA:TELEGRAM:LOGIN');
        final logs=await c.command('/system/logging/print');
        if(!logs.any((r)=>(r['comment']??'')=='NOVA:TELEGRAM:ACCOUNT-LOG')){
          await c.command('/system/logging/add',args:{'topics':'account','action':'memory','comment':'NOVA:TELEGRAM:ACCOUNT-LOG'});
        }
      }
      if(_wanAlerts){for(final host in wan){await _upsertNetwatch('WAN',host,'WAN probe');}}
      if(_towerAlerts){for(final host in towers){await _upsertNetwatch('TOWER',host,'tower');}}
      _toast('تم تركيب تنبيهات الراوتر. جرّب إرسال رسالة ثم تحقق من وصولها إلى تيليجرام.');
      await _load();
    }catch(e){_toast('لم تكتمل كل الإعدادات: '+_err(e)+'. راجع التعليقات NOVA:TELEGRAM.',bad:true);await _load();}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _testMessage() async{
    final c=_client;if(c==null||_busy)return;
    final token=_token.text.trim(),chat=_chat.text.trim();
    if(!RegExp(r'^[0-9]{5,}:[A-Za-z0-9_-]{20,}$').hasMatch(token)||!RegExp(r'^-?[0-9]+$|^@[A-Za-z0-9_]{5,}$').hasMatch(chat)){_toast('أدخل Bot Token وChat ID صالحين أولاً.',bad:true);return;}
    setState(()=>_busy=true);
    const tempName='NOVA-Telegram-Test-Once';
    try{
      final scripts=await c.command('/system/script/print');
      final old=scripts.where((r)=>r['name']==tempName).toList();
      for(final row in old){final id=row['.id']??row['id'];if(id!=null&&(row['comment']??'').startsWith('NOVA:TELEGRAM:'))await c.command('/system/script/remove',args:{'.id':id});}
      final source=':local url ("https://api.telegram.org/bot'+token+'/sendMessage?chat_id='+chat+'&text='+_encoded('NOVA test message from RouterOS')+'); /tool/fetch url=\$url keep-result=no check-certificate=yes;';
      await c.command('/system/script/add',args:{'name':tempName,'source':source,'policy':'read,write,policy,test,sensitive','comment':'NOVA:TELEGRAM:TEST'});
      final added=await c.command('/system/script/print');
      final row=added.where((r)=>r['name']==tempName).first;
      final id=row['.id']??row['id'];
      if(id==null)throw StateError('تعذر العثور على سكريبت الرسالة التجريبية.');
      await c.command('/system/script/run',args:{'number':id});
      await c.command('/system/script/remove',args:{'.id':id});
      _toast('أُرسل طلب التجربة من الراوتر. تحقق من وصول الرسالة إلى تيليجرام.');
    }catch(e){_toast('فشل إرسال التجربة: '+_err(e),bad:true);}
    finally{if(mounted)setState(()=>_busy=false);await _load();}
  }
  Future<void> _removeOwned() async{
    final c=_client;if(c==null||_busy)return;
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(backgroundColor:_panel,title:const Text('حذف نظام تيليجرام؟'),content:const Text('سيحذف سكريبتات وجدولات وNetwatch وتعليمات logging التي تحمل تعليقات NOVA:TELEGRAM فقط.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),style:FilledButton.styleFrom(backgroundColor:_red),child:const Text('حذف'))]))??false;
    if(!ok)return;setState(()=>_busy=true);
    try{
      final configs=await Future.wait([c.command('/tool/netwatch/print'),c.command('/system/scheduler/print'),c.command('/system/script/print'),c.command('/system/logging/print')]);
      const paths=['/tool/netwatch/remove','/system/scheduler/remove','/system/script/remove','/system/logging/remove'];
      for(var i=0;i<configs.length;i++){for(final row in configs[i]){if((row['comment']??'').startsWith('NOVA:TELEGRAM:')){final id=row['.id']??row['id'];if(id!=null)await c.command(paths[i],args:{'.id':id});}}}
      _toast('تم حذف عناصر NOVA:TELEGRAM.');await _load();
    }catch(e){_toast(_err(e),bad:true);await _load();}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Widget _card(String title,Widget child)=>Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:_panel,borderRadius:BorderRadius.circular(17),border:Border.all(color:Colors.white.withOpacity(.07))),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[Text(title,style:const TextStyle(color:Colors.white,fontSize:14,fontWeight:FontWeight.w800)),const SizedBox(height:10),child]));
  Widget _check(String title,String subtitle,bool value,ValueChanged<bool?> onChanged)=>CheckboxListTile(value:value,onChanged:_busy?null:onChanged,activeColor:_accent,controlAffinity:ListTileControlAffinity.leading,contentPadding:EdgeInsets.zero,dense:true,title:Text(title,style:const TextStyle(color:Colors.white,fontSize:12,fontWeight:FontWeight.w700)),subtitle:Text(subtitle,style:const TextStyle(color:_muted,fontSize:10)),);
  InputDecoration _dec(String title,{String? hint})=>InputDecoration(labelText:title,hintText:hint,labelStyle:const TextStyle(color:_muted,fontSize:12),filled:true,fillColor:const Color(0xFF0B1019),border:OutlineInputBorder(borderRadius:BorderRadius.circular(12)));
  @override Widget build(BuildContext context){
    if(_client==null)return Scaffold(backgroundColor:_bg,appBar:AppBar(title:const Text('Telegram Bot Reporter')),body:const Center(child:Text('اتصل بالراوتر أولاً.')));
    return Scaffold(backgroundColor:_bg,appBar:AppBar(backgroundColor:_bg,foregroundColor:Colors.white,title:const Text('تنبيهات تيليجرام من الراوتر',style:TextStyle(fontSize:16)),actions:[IconButton(onPressed:_busy?_load:null,icon:const Icon(Icons.refresh,color:_accent))]),body:_loading?const Center(child:CircularProgressIndicator(color:_accent)):ListView(padding:const EdgeInsets.all(14),children:[
      _card('ربط الراوتر ببوت تيليجرام بضغطة زر',const Text('تُنشأ السكريبتات داخل الراوتر وتعمل دون بقاء التطبيق مفتوحاً. يتطلب ذلك وصول الراوتر إلى Telegram API عبر HTTPS ووجود DNS ووقت صحيح وشهادات موثوقة.',style:TextStyle(color:Colors.white70,fontSize:12,height:1.5))),
      _card('بيانات البوت',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        TextField(controller:_token,textDirection:TextDirection.ltr,autocorrect:false,enableSuggestions:false,obscureText:_hideToken,decoration:_dec('Bot Token').copyWith(suffixIcon:IconButton(onPressed:()=>setState(()=>_hideToken=!_hideToken),icon:Icon(_hideToken?Icons.visibility:Icons.visibility_off,color:_muted)))),
        const SizedBox(height:10),TextField(controller:_chat,textDirection:TextDirection.ltr,autocorrect:false,decoration:_dec('Chat ID',hint:'123456789 أو @channel_name')),
      ])),
      _card('التنبيهات المطلوبة',Column(children:[
        _check('انقطاع/عودة الإنترنت','Netwatch يفحص عناوين الهدف وفق جدول التوجيه الحالي.',_wanAlerts,(v)=>setState(()=>_wanAlerts=v??false)),
        if(_wanAlerts)Padding(padding:const EdgeInsets.only(left:8,right:8,bottom:8),child:TextField(controller:_wanHosts,textDirection:TextDirection.ltr,decoration:_dec('أهداف فحص الإنترنت مفصولة بفواصل',hint:'1.1.1.1,8.8.8.8'))),
        _check('انقطاع الصحون والأبراج','أضف IPs الصحون الرئيسية؛ لكل هدف Netwatch يرسل DOWN / restored.',_towerAlerts,(v)=>setState(()=>_towerAlerts=v??false)),
        if(_towerAlerts)Padding(padding:const EdgeInsets.only(left:8,right:8,bottom:8),child:TextField(controller:_towerHosts,textDirection:TextDirection.ltr,decoration:_dec('IPs الصحون والأبراج مفصولة بفواصل',hint:'192.168.88.10,192.168.88.11'))),
        _check('تنبيه أمني وحرارة/CPU','مراقبة CPU والحرارة كل دقيقة عند تجاوز 85%/°C، ومراقبة أحداث account في سجل الراوتر.',_securityAlerts,(v)=>setState(()=>_securityAlerts=v??false)),
      ])),
      _card('حالة نظام التنبيهات',Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Text('Scripts: '+_scripts.length.toString()+' • Scheduler: '+_schedulers.length.toString()+' • Netwatch: '+_netwatch.length.toString(),style:const TextStyle(color:_green,fontSize:12,fontWeight:FontWeight.w700)),
        const SizedBox(height:7),Text(_scripts.isEmpty?'لم يتم تركيب التنبيهات بعد.':'العناصر الحالية التي يديرها NOVA ظاهرة هنا.',style:const TextStyle(color:_muted,fontSize:11)),
        if(_error!=null)Padding(padding:const EdgeInsets.only(top:8),child:Text(_error!,style:const TextStyle(color:_red,fontSize:11))),
        const SizedBox(height:12),FilledButton.icon(onPressed:_busy?null:_install,style:FilledButton.styleFrom(backgroundColor:_accent),icon:_busy?const SizedBox(width:17,height:17,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.notifications_active),label:Text(_busy?'جارٍ حقن الإعدادات...':'تفعيل وحقن نظام التنبيهات في الراوتر')),
        const SizedBox(height:8),OutlinedButton.icon(onPressed:_busy?null:_testMessage,icon:const Icon(Icons.send_rounded),label:const Text('إرسال رسالة تجريبية الآن')),
        const SizedBox(height:8),TextButton.icon(onPressed:_busy?null:_removeOwned,style:TextButton.styleFrom(foregroundColor:_red),icon:const Icon(Icons.delete_outline),label:const Text('حذف نظام تنبيهات NOVA')),
      ])),
      _card('ملاحظات مهمة',const Text('تُخزّن Bot Token داخل System Script على الراوتر. احمِ صلاحيات scripts وAPI. تنبيهات WAN تعتمد على عناوين Netwatch والتوجيه الحالي؛ إذا استُخدم PCC أو تعدد WAN، وجّه أهداف الفحص عبر كل خط بسياسة routing مناسبة. تنبيه الحرارة يعتمد على وجود قيمة cpu-temperature في /system/health.',style:TextStyle(color:Colors.white70,fontSize:11,height:1.5))),
    ]));
  }
}
