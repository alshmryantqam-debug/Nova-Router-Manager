import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/routeros_client.dart';
import '../../core/providers/router_providers.dart';
import 'ip_arp_dns_service.dart';

const Color _ipBg = Color(0xFF080B12);
const Color _ipPanel = Color(0xFF111722);
const Color _ipMuted = Color(0xFF8D9AB0);
const Color _ipAccent = Color(0xFF8B7CFF);
const Color _ipGreen = Color(0xFF43D9A3);
const Color _ipRed = Color(0xFFFF657A);

class IpArpDnsScreen extends ConsumerStatefulWidget {
  const IpArpDnsScreen({super.key});
  @override
  ConsumerState<IpArpDnsScreen> createState() => _IpArpDnsScreenState();
}

class _IpArpDnsScreenState extends ConsumerState<IpArpDnsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  IpArpDnsService? _service;
  List<Map<String, String>> _addresses = [];
  List<Map<String, String>> _arp = [];
  List<Map<String, String>> _pools = [];
  List<Map<String, String>> _dnsStatic = [];
  Map<String, String> _dns = {};
  List<Map<String, String>> _interfaces = [];
  List<Map<String, String>> _cache = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final client = ref.read(activeRouterClientProvider);
    if (client != null) {
      _service = IpArpDnsService(client);
      _loadAll();
    } else {
      _loading = false;
      _error = 'اتصل بالراوتر أولاً.';
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  String _friendly(Object error) => error.toString().replaceFirst('RouterOsException: ', '').replaceFirst('Exception: ', '');

  Future<void> _loadAll() async {
    final service = _service;
    if (service == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await Future.wait<List<Map<String, String>>>([
        service.listAddresses(),
        service.listArp(),
        service.listPools(),
        service.listDnsSettings(),
        service.listDnsStatic(),
        service.client.command('/interface/print', args: const {'.proplist': 'name,type'}),
        service.client.command('/ip/dns/cache/print', args: const {'.proplist': 'name,type,data,ttl'}),
      ]);
      if (!mounted) return;
      setState(() {
        _addresses = result[0]; _arp = result[1]; _pools = result[2];
        _dns = result[3].isEmpty ? {} : result[3].first;
        _dnsStatic = result[4]; _interfaces = result[5]; _cache = result[6];
        _loading = false;
      });
    } catch (error) {
      if (mounted) setState(() { _loading = false; _error = _friendly(error); });
    }
  }

  Future<void> _perform(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success), backgroundColor: const Color(0xFF176D58)));
      await _loadAll();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('فشلت العملية: ${_friendly(error)}'), backgroundColor: const Color(0xFF8C3042)));
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<Map<String, String>?> _formDialog(String title, List<_Field> fields) async {
    final controllers = <String, TextEditingController>{for (final f in fields) f.key: TextEditingController(text: f.initial)};
    final form = GlobalKey<FormState>();
    final result = await showDialog<Map<String, String>>(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: _ipPanel,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      content: SizedBox(width: 440, child: Form(key: form, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final f in fields) Padding(padding: const EdgeInsets.only(bottom: 10), child: TextFormField(
          controller: controllers[f.key], keyboardType: f.numeric ? TextInputType.number : TextInputType.text,
          style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
          decoration: InputDecoration(labelText: f.label, hintText: f.hint, helperText: f.helper),
          validator: f.required ? (v) => v == null || v.trim().isEmpty ? 'هذا الحقل مطلوب' : null : null,
        )),
      ])))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(onPressed: () {
          if (form.currentState?.validate() != true) return;
          Navigator.pop(ctx, {for (final f in fields) f.key: controllers[f.key]!.text.trim()});
        }, child: const Text('حفظ')),
      ],
    ));
    for (final controller in controllers.values) { controller.dispose(); }
    return result;
  }

  Future<bool> _confirm(String title, String detail) async => await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
    backgroundColor: _ipPanel, title: Text(title, style: const TextStyle(color: Colors.white)),
    content: Text(detail, style: const TextStyle(color: _ipMuted)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد')),
    ],
  )) ?? false;

  Future<void> _addAddress() async {
    final data = await _formDialog('إضافة عنوان IP', [
      const _Field('address','Address / CIDR',required:true,hint:'192.168.10.1/24'),
      _Field('interface','المنفذ',required:true,hint:'ether1',helper:'الأسماء المتاحة: ${_interfaces.map((e)=>e['name']).join(', ')}'),
      const _Field('comment','Comment'),
    ]);
    if (data == null || _service == null) return;
    await _perform(() => _service!.addAddress(address:data['address']!,interface:data['interface']!,comment:data['comment']!), 'تمت إضافة عنوان IP.');
  }

  Future<void> _editAddress(Map<String,String> row) async {
    final id=row['.id']; if(id==null) return;
    final data=await _formDialog('تعديل عنوان IP',[
      _Field('address','Address / CIDR',required:true,initial:row['address']??''),
      _Field('interface','المنفذ',required:true,initial:row['interface']??''),
      _Field('comment','Comment',initial:row['comment']??''),
    ]);
    if(data==null||_service==null)return;
    await _perform(() => _service!.updateAddress(id,address:data['address'],interface:data['interface'],comment:data['comment']), 'تم تحديث عنوان IP.');
  }

  Future<void> _addPool() async {
    final data=await _formDialog('إضافة IP Pool',[
      const _Field('name','اسم النطاق',required:true,hint:'hotspot-pool'),
      const _Field('ranges','Range أو نطاقات مفصولة بفواصل',required:true,hint:'192.168.10.10-192.168.10.250'),
      const _Field('comment','Comment'),
    ]);
    if(data==null||_service==null)return;
    await _perform(() => _service!.addPool(name:data['name']!,ranges:data['ranges']!,comment:data['comment']!), 'تم إنشاء IP Pool.');
  }

  Future<void> _editPool(Map<String,String> row) async {
    final id=row['.id']; if(id==null)return;
    final data=await _formDialog('تعديل IP Pool',[
      _Field('name','اسم النطاق',required:true,initial:row['name']??''),
      _Field('ranges','Ranges',required:true,initial:row['ranges']??''),
      _Field('comment','Comment',initial:row['comment']??''),
    ]);
    if(data==null||_service==null)return;
    await _perform(() => _service!.updatePool(id,name:data['name'],ranges:data['ranges'],comment:data['comment']), 'تم تحديث IP Pool.');
  }

  Future<void> _addStaticDns() async {
    final data=await _formDialog('إضافة DNS Static',[
      const _Field('name','اسم النطاق',required:true,hint:'local.server أو ads.example'),
      const _Field('address','عنوان IP أو اتركه فارغاً لنوع سجل خاص'),
      const _Field('type','Type اختياري',hint:'A / AAAA / NXDOMAIN / FWD'),
      const _Field('comment','Comment'),
    ]);
    if(data==null||_service==null)return;
    await _perform(() => _service!.addDnsStatic(name:data['name']!,address:data['address'],type:data['type'],comment:data['comment']), 'تمت إضافة DNS Static.');
  }

  Future<void> _setDns() async {
    final current=_dns['servers']??'';
    final data=await _formDialog('تغيير DNS Servers',[
      _Field('servers','عناوين DNS مفصولة بفواصل',required:true,initial:current,hint:'1.1.1.1,8.8.8.8'),
    ]);
    if(data==null||_service==null)return;
    if(!await _confirm('تغيير DNS للراوتر؟','سيؤثر هذا على عملاء DNS الذين يستخدمون الراوتر.'))return;
    await _perform(() => _service!.setDnsServers(data['servers']!), 'تم تحديث DNS Servers.');
  }

  Future<void> _removeArp(Map<String,String> row) async {
    final id=row['.id']; if(id==null||_service==null)return;
    if(!await _confirm('حذف إدخال ARP؟','سيُحذف ${row['address']??'IP'} / ${row['mac-address']??'MAC'} من جدول ARP.'))return;
    await _perform(() => _service!.removeArp(id), 'تم حذف إدخال ARP.');
  }

  Future<void> _removeAddress(Map<String,String> row) async {
    final id=row['.id']; if(id==null||_service==null)return;
    if(!await _confirm('حذف عنوان IP؟','سيتم حذف ${row['address']??''} من إعدادات الراوتر.'))return;
    await _perform(() => _service!.removeAddress(id), 'تم حذف عنوان IP.');
  }

  Future<void> _removePool(Map<String,String> row) async {
    final id=row['.id']; if(id==null||_service==null)return;
    if(!await _confirm('حذف IP Pool؟','قد تتأثر إعدادات DHCP أو PPPoE أو Hotspot التي تستخدم هذا النطاق.'))return;
    await _perform(() => _service!.removePool(id), 'تم حذف IP Pool.');
  }

  Widget _panel({required String title, required Widget child, Widget? action}) => Container(
    margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(color: _ipPanel, borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(.06))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children:[Expanded(child:Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w800))),if(action!=null)action]),
      const SizedBox(height:10),child,
    ]),
  );

  Widget _empty(String value) => Padding(padding: const EdgeInsets.all(18), child: Center(child: Text(value, style: const TextStyle(color: _ipMuted))));

  Widget _rowCard(String title, String subtitle, {required IconData icon, required Color color, List<Widget> actions = const []}) => Container(
    margin: const EdgeInsets.only(bottom:7), padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(color: const Color(0xFF0B1019), borderRadius: BorderRadius.circular(11)),
    child: Row(children:[
      Icon(icon,color:color,size:20),const SizedBox(width:9),
      Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(title,style:const TextStyle(color:Colors.white,fontWeight:FontWeight.w700,fontFamily:'monospace',fontSize:12)),
        const SizedBox(height:4),Text(subtitle,style:const TextStyle(color:_ipMuted,fontSize:10)),
      ])),
      ...actions,
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final client=ref.watch(activeRouterClientProvider);
    if(client==null||_service==null)return const Scaffold(backgroundColor:_ipBg,body:Center(child:Text('اتصل بالراوتر أولاً.',style:TextStyle(color:Colors.white))));
    return Scaffold(
      backgroundColor:_ipBg,
      appBar:AppBar(backgroundColor:_ipBg,foregroundColor:Colors.white,title:const Text('IP • ARP • DNS'),
        actions:[IconButton(onPressed:_busy||_loading?null:_loadAll,icon:const Icon(Icons.refresh_rounded))],
        bottom:TabBar(controller:_tabs,isScrollable:true,indicatorColor:_ipAccent,labelColor:Colors.white,unselectedLabelColor:_ipMuted,tabs:const[
          Tab(icon:Icon(Icons.lan_outlined,size:17),text:'IP Addresses'),
          Tab(icon:Icon(Icons.hub_outlined,size:17),text:'ARP Table'),
          Tab(icon:Icon(Icons.dns_outlined,size:17),text:'DNS & Cache'),
          Tab(icon:Icon(Icons.route_outlined,size:17),text:'IP Pools'),
        ]),
      ),
      body:_loading?const Center(child:CircularProgressIndicator(color:_ipAccent)):Column(children:[
        if(_error!=null)Container(width:double.infinity,padding:const EdgeInsets.all(10),color:const Color(0xFF3A1721),child:Text(_error!,style:const TextStyle(color:_ipRed,fontSize:12))),
        Expanded(child:TabBarView(controller:_tabs,children:[
          _addressesTab(),_arpTab(),_dnsTab(),_poolsTab(),
        ])),
      ]),
    );
  }

  Widget _addressesTab()=>ListView(padding:const EdgeInsets.all(12),children:[
    _panel(title:'عناوين IP على جميع الواجهات',action:IconButton(onPressed:_busy?null:_addAddress,icon:const Icon(Icons.add_circle_outline,color:_ipAccent)),child:Column(children:[
      if(_addresses.isEmpty)_empty('لا توجد عناوين IP أو لم تُحمّل البيانات.')
      else ..._addresses.map((row)=>_rowCard(row['address']??'—','${row['interface']??'—'} • ${row['network']??''} • ${row['comment']??''}',icon:Icons.lan,color:row['disabled']=='true'?_ipRed:_ipGreen,actions:[
        IconButton(tooltip:'تعديل',onPressed:_busy?null:()=>_editAddress(row),icon:const Icon(Icons.edit_outlined,color:_ipAccent,size:18)),
        IconButton(tooltip:row['disabled']=='true'?'تفعيل':'تعطيل',onPressed:_busy||row['.id']==null?null:()=>_perform(()=>_service!.setAddressDisabled(row['.id']!,row['disabled']!='true'),'تم تحديث حالة عنوان IP.'),icon:Icon(row['disabled']=='true'?Icons.play_arrow:Icons.pause,color:_ipMuted,size:18)),
        IconButton(tooltip:'حذف',onPressed:_busy?null:()=>_removeAddress(row),icon:const Icon(Icons.delete_outline,color:_ipRed,size:18)),
      ])),
    ])),
  ]);

  Widget _arpTab()=>ListView(padding:const EdgeInsets.all(12),children:[
    _panel(title:'جدول ARP',action:IconButton(onPressed:_busy?null:_loadAll,icon:const Icon(Icons.refresh,color:_ipAccent)),child:Column(children:[
      if(_arp.isEmpty)_empty('جدول ARP فارغ.')
      else ..._arp.map((row){
        final status=row['status']??(row['dynamic']=='true'?'dynamic':'static');
        final dynamic=row['dynamic']=='true';
        return _rowCard(row['address']??'—','${row['mac-address']??'MAC غير متاح'} • ${row['interface']??'—'} • $status',icon:Icons.devices_other,color:dynamic?_ipAccent:_ipGreen,actions:[
          if(dynamic)IconButton(tooltip:'تثبيت IP/MAC',onPressed:_busy||row['.id']==null?null:()=>_perform(()=>_service!.makeArpStatic(row['.id']!),'تم طلب تثبيت إدخال ARP.'),icon:const Icon(Icons.push_pin_outlined,color:_ipGreen,size:18)),
          IconButton(tooltip:'حذف الإدخال',onPressed:_busy?null:()=>_removeArp(row),icon:const Icon(Icons.delete_outline,color:_ipRed,size:18)),
        ]);
      }),
    ])),
  ]);

  Widget _dnsTab()=>ListView(padding:const EdgeInsets.all(12),children:[
    _panel(title:'إعدادات DNS',action:IconButton(onPressed:_busy?null:_setDns,icon:const Icon(Icons.edit_outlined,color:_ipAccent)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('Servers: ${_dns['servers']??'غير محدد'}',style:const TextStyle(color:Colors.white,fontFamily:'monospace')),
      const SizedBox(height:6),Text('Dynamic Servers: ${_dns['dynamic-servers']??'—'}',style:const TextStyle(color:_ipMuted,fontSize:11)),
      Text('Allow Remote Requests: ${_dns['allow-remote-requests']??'—'}',style:const TextStyle(color:_ipMuted,fontSize:11)),
      Text('Cache: ${_dns['cache-used']??'—'} / ${_dns['cache-size']??'—'}',style:const TextStyle(color:_ipGreen,fontSize:11)),
      const SizedBox(height:8),Wrap(spacing:8,children:[
        FilledButton.tonalIcon(onPressed:_busy?null:()=>_perform(()=>_service!.flushDnsCache(),'تم إرسال أمر تفريغ DNS cache.'),icon:const Icon(Icons.cleaning_services_outlined),label:const Text('Flush DNS Cache')),
        OutlinedButton.icon(onPressed:_busy?null:_addStaticDns,icon:const Icon(Icons.add),label:const Text('DNS Static')),
      ]),
    ])),
    _panel(title:'DNS Static Entries (${_dnsStatic.length})',child:Column(children:[
      if(_dnsStatic.isEmpty)_empty('لا توجد سجلات ثابتة.')
      else ..._dnsStatic.map((row)=>_rowCard(row['name']??'—','${row['address']??row['type']??'—'} • ${row['comment']??''}',icon:Icons.dns,color:_ipAccent,actions:[
        IconButton(tooltip:'حذف السجل',onPressed:_busy||row['.id']==null?null:()=>_perform(()=>_service!.removeDnsStatic(row['.id']!), 'تم حذف سجل DNS Static.'),icon:const Icon(Icons.delete_outline,color:_ipRed,size:18)),
      ])),
    ])),
    _panel(title:'DNS Cache Entries (${_cache.length})',child:Column(children:[
      if(_cache.isEmpty)_empty('لا توجد سجلات كاش ظاهرة أو لا يدعمها الراوتر.')
      else ..._cache.take(80).map((row)=>_rowCard(row['name']??'—','${row['data']??''} • TTL ${row['ttl']??'—'}',icon:Icons.cached,color:_ipMuted)),
    ])),
  ]);

  Widget _poolsTab()=>ListView(padding:const EdgeInsets.all(12),children:[
    _panel(title:'IP Pools',action:IconButton(onPressed:_busy?null:_addPool,icon:const Icon(Icons.add_circle_outline,color:_ipAccent)),child:Column(children:[
      if(_pools.isEmpty)_empty('لا توجد IP Pools.')
      else ..._pools.map((row)=>_rowCard(row['name']??'—', '${row['ranges']??'—'} • ${row['comment']??''}',icon:Icons.route,color:_ipGreen,actions:[
        IconButton(tooltip:'تعديل النطاق',onPressed:_busy?null:()=>_editPool(row),icon:const Icon(Icons.edit_outlined,color:_ipAccent,size:18)),
        IconButton(tooltip:'حذف النطاق',onPressed:_busy?null:()=>_removePool(row),icon:const Icon(Icons.delete_outline,color:_ipRed,size:18)),
      ])),
    ])),
  ]);
}

class _Field {
  const _Field(this.key,this.label,{this.required=false,this.initial='',this.hint='',this.helper='',this.numeric=false});
  final String key,label,initial,hint,helper;
  final bool required,numeric;
}
