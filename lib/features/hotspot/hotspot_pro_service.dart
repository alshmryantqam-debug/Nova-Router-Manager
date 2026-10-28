import '../../core/network/routeros_client.dart';

enum HotspotCardStatus { unused, active, timeExpired, quotaReached }

class HotspotProUser {
  const HotspotProUser({
    required this.id,
    required this.name,
    required this.profile,
    required this.comment,
    required this.disabled,
    required this.uptime,
    required this.limitUptime,
    required this.bytesIn,
    required this.bytesOut,
    required this.limitBytesTotal,
    required this.macAddress,
    required this.status,
  });

  final String id;
  final String name;
  final String profile;
  final String comment;
  final bool disabled;
  final String uptime;
  final String limitUptime;
  final int bytesIn;
  final int bytesOut;
  final int limitBytesTotal;
  final String macAddress;
  final HotspotCardStatus status;

  int get consumedBytes => bytesIn + bytesOut;
  String get batch => RegExp(r'NOVA-BATCH=([^|\s]+)').firstMatch(comment)?.group(1) ?? '';
  DateTime? get expiry {
    final iso = RegExp(r'(?:^|[|\s])EXP:(\d{4}-\d{2}-\d{2})').firstMatch(comment)?.group(1);
    if (iso != null) return DateTime.tryParse(iso);
    final epoch = RegExp(r'NOVA_EXP_TS=([^|]+)').firstMatch(comment)?.group(1);
    if (epoch != null) {
      final seconds = int.tryParse(epoch.trim());
      if (seconds != null && seconds > 0) return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    }
    return null;
  }

  factory HotspotProUser.fromMap(Map<String, String> row) {
    int num(String key) => int.tryParse(row[key] ?? '') ?? 0;
    final uptime = row['uptime'] ?? '0s';
    final limitUptime = row['limit-uptime'] ?? '';
    final bytesIn = num('bytes-in');
    final bytesOut = num('bytes-out');
    final quota = num('limit-bytes-total');
    final comment = row['comment'] ?? '';
    final expiryText = RegExp(r'(?:^|[|\s])EXP:(\d{4}-\d{2}-\d{2})').firstMatch(comment)?.group(1);
    final expiry = expiryText == null ? null : DateTime.tryParse(expiryText);
    final now = DateTime.now();
    final dateExpired = expiry != null && DateTime(expiry.year, expiry.month, expiry.day).isBefore(DateTime(now.year, now.month, now.day));
    final expiredMarker = comment.contains('NOVA_EXPIRED');
    final timeExpired = expiredMarker || dateExpired || (_durationSeconds(limitUptime) > 0 && _durationSeconds(uptime) >= _durationSeconds(limitUptime));
    final quotaReached = quota > 0 && bytesIn + bytesOut >= quota;
    final unused = _durationSeconds(uptime) == 0 && bytesIn + bytesOut == 0;
    final status = timeExpired
        ? HotspotCardStatus.timeExpired
        : quotaReached
            ? HotspotCardStatus.quotaReached
            : unused
                ? HotspotCardStatus.unused
                : HotspotCardStatus.active;
    return HotspotProUser(
      id: row['.id'] ?? '',
      name: row['name'] ?? '',
      profile: row['profile'] ?? 'default',
      comment: comment,
      disabled: row['disabled'] == 'true',
      uptime: uptime,
      limitUptime: limitUptime,
      bytesIn: bytesIn,
      bytesOut: bytesOut,
      limitBytesTotal: quota,
      macAddress: row['mac-address'] ?? '',
      status: status,
    );
  }
}

class HotspotProService {
  const HotspotProService(this.client);
  final RouterOsClient client;

  Future<List<HotspotProUser>> fetchUsers() async {
    final rows = await client.command('/ip/hotspot/user/print', args: const {
      '.proplist': '.id,name,profile,comment,disabled,uptime,limit-uptime,bytes-in,bytes-out,limit-bytes-total,mac-address',
    });
    return rows.map(HotspotProUser.fromMap).where((u) => u.name.isNotEmpty).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<List<Map<String, String>>> fetchHosts() => client.command('/ip/hotspot/host/print', args: const {
    '.proplist': '.id,mac-address,address,to-address,server,uptime,authorized',
  });

  Future<List<Map<String, String>>> fetchCookies() => client.command('/ip/hotspot/cookie/print', args: const {
    '.proplist': '.id,user,mac-address,domain,expires,profile',
  });

  Future<List<Map<String, String>>> fetchQueues() => client.command('/queue/simple/print', args: const {'.proplist': '.id,name'});

  Future<void> resetMac(String userId, String username) async {
    _requireId(userId);
    final users = await client.command('/ip/hotspot/user/print', args: const {
      '.proplist': '.id,name,mac-address',
    });
    String oldMac = '';
    for (final user in users) { if (user['.id'] == userId) { oldMac = user['mac-address'] ?? ''; break; } }
    await client.command('/ip/hotspot/user/set', args: {'.id': userId, 'mac-address': ''});
    await _removeMatching('/ip/hotspot/cookie/print', '/ip/hotspot/cookie/remove', 'user', username);
    await _removeMatching('/ip/hotspot/active/print', '/ip/hotspot/active/remove', 'user', username);
    if (oldMac.isNotEmpty) {
      final hosts = await fetchHosts();
      for (final host in hosts) {
        if (host['mac-address'] == oldMac && (host['.id'] ?? '').isNotEmpty) {
          await client.command('/ip/hotspot/host/remove', args: {'.id': host['.id']!});
        }
      }
    }
  }

  Future<void> resetCounters(String userId) async {
    _requireId(userId);
    await client.command('/ip/hotspot/user/reset-counters', args: {'.id': userId});
  }

  Future<void> topUpTime(String userId, String currentLimit, String extraDuration) async {
    _requireId(userId);
    final extra = _durationSeconds(extraDuration);
    if (extra <= 0) throw ArgumentError('أدخل مدة إضافية صحيحة مثل 2h أو 1d.');
    final base = _durationSeconds(currentLimit);
    final total = base + extra;
    if (total <= 0) throw ArgumentError('تعذر حساب حد الوقت الحالي.');
    await client.command('/ip/hotspot/user/set', args: {'.id': userId, 'limit-uptime': _formatDuration(total)});
  }

  Future<void> topUpQuota(String userId, int currentLimitBytes, int extraBytes) async {
    _requireId(userId);
    if (extraBytes <= 0 || currentLimitBytes < 0) throw ArgumentError('حجم الجيجابايت الإضافي غير صالح.');
    final total = currentLimitBytes + extraBytes;
    await client.command('/ip/hotspot/user/set', args: {'.id': userId, 'limit-bytes-total': total.toString()});
  }

  Future<int> deleteBatch(String batchId) async {
    final batch = batchId.trim();
    if (batch.isEmpty) throw ArgumentError('اسم الدفعة مطلوب.');
    final users = await fetchUsers();
    final targets = users.where((u) => u.id.isNotEmpty && (u.batch == batch || u.comment.contains(batch))).toList();
    for (final user in targets) {
      await client.command('/ip/hotspot/user/remove', args: {'.id': user.id});
    }
    return targets.length;
  }

  Future<int> deleteExpiredUsers() async {
    final users = await fetchUsers();
    final targets = users.where((u) => u.id.isNotEmpty &&
        (u.status == HotspotCardStatus.timeExpired || u.status == HotspotCardStatus.quotaReached)).toList();
    for (final user in targets) {
      await client.command('/ip/hotspot/user/remove', args: {'.id': user.id});
    }
    return targets.length;
  }

  Future<void> saveSmartProfile({
    required String name,
    required String rateLimit,
    required int sharedUsers,
    required String expiryMode,
    required bool lockUserMac,
    required String parentQueue,
  }) async {
    final normalized = name.trim();
    if (normalized.isEmpty) throw ArgumentError('اسم الباقة مطلوب.');
    if (!const {'remove', 'disable'}.contains(expiryMode)) throw ArgumentError('وضع الانتهاء غير صالح.');
    final profiles = await client.command('/ip/hotspot/user/profile/print', args: const {'.proplist': '.id,name'});
    Map<String, String>? old;
    for (final profile in profiles) { if (profile['name'] == normalized) { old = profile; break; } }
    final oldScript = lockUserMac ? _macLockScript() : '';
    final expiryScript = expiryMode == 'remove'
        ? ':local u $user; :local id [/ip hotspot user find where name=$u]; :if ([:len $id] > 0) do={ /ip hotspot user remove $id; }'
        : ':local u $user; :local id [/ip hotspot user find where name=$u]; :if ([:len $id] > 0) do={ /ip hotspot user disable $id; }';
    final script = [oldScript, expiryScript].where((s) => s.isNotEmpty).join('\n');
    final comment = 'NOVA_EXPIRY_MODE=$expiryMode|NOVA_LOCK_MAC=$lockUserMac|NOVA_PARENT_QUEUE=$parentQueue';
    final args = <String, String>{
      'name': normalized,
      'rate-limit': rateLimit.trim(),
      'shared-users': sharedUsers.toString(),
      'on-login': script,
      'comment': comment,
    };
    if (parentQueue.trim().isNotEmpty) args['parent-queue'] = parentQueue.trim();
    if (old == null) {
      await client.command('/ip/hotspot/user/profile/add', args: args);
    } else {
      final id = old['.id'] ?? '';
      _requireId(id);
      await client.command('/ip/hotspot/user/profile/set', args: {'.id': id, ...args});
    }
  }

  String _macLockScript() => r'''
:local u $user;
:local id [/ip hotspot user find where name=$u];
:local mac $"mac-address";
:if ([:len $id] > 0 && [:len $mac] > 0) do={
  :local locked [/ip hotspot user get $id mac-address];
  :if ([:len $locked] = 0) do={ /ip hotspot user set $id mac-address=$mac; }
}
''';

  Future<void> _removeMatching(String printPath, String removePath, String field, String value) async {
    if (value.isEmpty) return;
    final rows = await client.command(printPath);
    for (final row in rows) {
      if (row[field] == value && (row['.id'] ?? '').isNotEmpty) {
        await client.command(removePath, args: {'.id': row['.id']!});
      }
    }
  }

  static int _durationSeconds(String value) {
    final input = value.trim();
    if (input.isEmpty) return 0;
    final regex = RegExp(r'(\d+)([wdhms])');
    var total = 0;
    for (final m in regex.allMatches(input)) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      switch (m.group(2)) {
        case 'w': total += n * 604800; break;
        case 'd': total += n * 86400; break;
        case 'h': total += n * 3600; break;
        case 'm': total += n * 60; break;
        case 's': total += n; break;
      }
    }
    return total;
  }

  static String _formatDuration(int seconds) {
    final parts = <String>[];
    for (final unit in <(String, int)>[('w', 604800), ('d', 86400), ('h', 3600), ('m', 60), ('s', 1)]) {
      final n = seconds ~/ unit.$2;
      if (n > 0) parts.add('$n${unit.$1}');
      seconds %= unit.$2;
    }
    return parts.isEmpty ? '1s' : parts.join();
  }

  static void _requireId(String id) {
    if (id.trim().isEmpty) throw ArgumentError('معرّف المستخدم غير متوفر.');
  }
}

int _durationSeconds(String value) => _durationSecondsImpl(value);

int _durationSecondsImpl(String value) {
  final regex = RegExp(r'(\d+)([wdhms])');
  var total = 0;
  for (final m in regex.allMatches(value.trim())) {
    final n = int.tryParse(m.group(1)!) ?? 0;
    switch (m.group(2)) {
      case 'w': total += n * 604800; break;
      case 'd': total += n * 86400; break;
      case 'h': total += n * 3600; break;
      case 'm': total += n * 60; break;
      case 's': total += n; break;
    }
  }
  return total;
}
