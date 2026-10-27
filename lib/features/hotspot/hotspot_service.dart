import 'dart:math';

import '../../core/network/routeros_client.dart';

enum HotspotCredentialMode { usernameOnly, usernameAndPassword }

class HotspotProfile {
  const HotspotProfile({
    required this.id,
    required this.name,
    required this.rateLimit,
    required this.comment,
    required this.validityDays,
    required this.validityHours,
  });

  final String id;
  final String name;
  final String rateLimit;
  final String comment;
  final int validityDays;
  final int validityHours;

  String get validityLabel {
    final parts = <String>[];
    if (validityDays > 0) parts.add(validityDays.toString() + ' يوم');
    if (validityHours > 0) parts.add(validityHours.toString() + ' ساعة');
    return parts.isEmpty ? 'بدون انتهاء تلقائي' : parts.join(' و');
  }

  factory HotspotProfile.fromMap(Map<String, String> row) {
    final comment = row['comment'] ?? '';
    final match = RegExp(r'NOVA_VALIDITY=(\d+)d(\d+)h').firstMatch(comment);
    return HotspotProfile(
      id: row['.id'] ?? '',
      name: row['name'] ?? '',
      rateLimit: row['rate-limit'] ?? '',
      comment: comment,
      validityDays: int.tryParse(match?.group(1) ?? '') ?? 0,
      validityHours: int.tryParse(match?.group(2) ?? '') ?? 0,
    );
  }
}

class HotspotActiveSession {
  const HotspotActiveSession({
    required this.id,
    required this.username,
    required this.address,
    required this.macAddress,
    required this.server,
    required this.uptime,
    required this.bytesIn,
    required this.bytesOut,
    required this.profile,
  });

  final String id;
  final String username;
  final String address;
  final String macAddress;
  final String server;
  final String uptime;
  final int bytesIn;
  final int bytesOut;
  final String profile;

  int get totalBytes => bytesIn + bytesOut;

  factory HotspotActiveSession.fromMap(Map<String, String> row) {
    int parseBytes(String key) => int.tryParse(row[key] ?? '') ?? 0;
    return HotspotActiveSession(
      id: row['.id'] ?? '',
      username: row['user'] ?? row['name'] ?? '—',
      address: row['address'] ?? '',
      macAddress: row['mac-address'] ?? '',
      server: row['server'] ?? '',
      uptime: row['uptime'] ?? '—',
      bytesIn: parseBytes('bytes-in'),
      bytesOut: parseBytes('bytes-out'),
      profile: row['profile'] ?? '',
    );
  }
}

class HotspotUser {
  const HotspotUser({
    required this.id,
    required this.username,
    required this.profile,
    required this.comment,
    required this.disabled,
    required this.limitUptime,
    required this.limitBytesTotal,
  });

  final String id;
  final String username;
  final String profile;
  final String comment;
  final bool disabled;
  final String limitUptime;
  final int limitBytesTotal;

  bool get isExpired => comment.contains('NOVA_EXPIRED');

  factory HotspotUser.fromMap(Map<String, String> row) => HotspotUser(
        id: row['.id'] ?? '',
        username: row['name'] ?? '',
        profile: row['profile'] ?? 'default',
        comment: row['comment'] ?? '',
        disabled: row['disabled'] == 'true',
        limitUptime: row['limit-uptime'] ?? '',
        limitBytesTotal: int.tryParse(row['limit-bytes-total'] ?? '') ?? 0,
      );
}

class HotspotVoucher {
  const HotspotVoucher({
    required this.username,
    required this.password,
    required this.profile,
    required this.batchId,
    required this.validityLabel,
    required this.price,
    required this.comment,
    required this.limitUptime,
    required this.limitBytesTotal,
  });

  final String username;
  final String password;
  final String profile;
  final String batchId;
  final String validityLabel;
  final String price;
  final String comment;
  final String limitUptime;
  final int limitBytesTotal;

  String qrPayload({String portalUrl = ''}) {
    final trimmedPortal = portalUrl.trim();
    if (trimmedPortal.isNotEmpty) {
      final parsed = Uri.tryParse(trimmedPortal);
      if (parsed != null &&
          (parsed.scheme == 'http' || parsed.scheme == 'https') &&
          parsed.host.isNotEmpty) {
        final parameters = <String, String>{
          ...parsed.queryParameters,
          'username': username,
        };
        if (password.isNotEmpty) parameters['password'] = password;
        return parsed.replace(queryParameters: parameters).toString();
      }
    }
    return password.isEmpty
        ? 'NOVA HOTSPOT\nusername=' + username
        : 'NOVA HOTSPOT\nusername=' + username + '\npassword=' + password;
  }
}

class VoucherBatchRequest {
  const VoucherBatchRequest({
    required this.count,
    required this.codeLength,
    required this.prefix,
    required this.profileName,
    required this.credentialMode,
    required this.batchId,
    this.limitBytesTotal = 0,
    this.limitUptime = '',
    this.price = '',
    this.validityLabel = '',
    this.comment = '',
  });

  final int count;
  final int codeLength;
  final String prefix;
  final String profileName;
  final HotspotCredentialMode credentialMode;
  final String batchId;
  final int limitBytesTotal;
  final String limitUptime;
  final String price;
  final String validityLabel;
  final String comment;
}

class HotspotService {
  HotspotService(this._client);

  final RouterOsClient _client;
  static const String _characterSet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final Random _random = Random.secure();

  Future<List<HotspotProfile>> fetchProfiles() async {
    final rows = await _client.command(
      '/ip/hotspot/user/profile/print',
      args: const <String, String>{
        '.proplist': '.id,name,rate-limit,comment,shared-users,session-timeout',
      },
    );
    final profiles = rows
        .map(HotspotProfile.fromMap)
        .where((profile) => profile.name.isNotEmpty)
        .toList(growable: false)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return profiles;
  }

  Future<HotspotProfile> createOrUpdateProfile({
    required String name,
    required String rateLimit,
    required int validityDays,
    required int validityHours,
    int sharedUsers = 1,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'اسم الباقة مطلوب.');
    }
    if (validityDays < 0 || validityHours < 0 || validityHours > 23) {
      throw ArgumentError('مدة الصلاحية غير صحيحة.');
    }
    if (validityDays == 0 && validityHours == 0) {
      throw ArgumentError('مدة الصلاحية يجب أن تكون يومًا أو ساعة واحدة على الأقل.');
    }
    if (sharedUsers < 1 || sharedUsers > 1000) {
      throw ArgumentError.value(sharedUsers, 'sharedUsers', 'قيمة المستخدمين المشتركين غير صحيحة.');
    }

    final validity = _formatValidity(validityDays, validityHours);
    final onLogin = buildExpiryOnLoginScript(validity);
    final profileComment = 'NOVA|NOVA_VALIDITY=' +
        validityDays.toString() +
        'd' +
        validityHours.toString() +
        'h';
    final existing = await fetchProfiles();
    HotspotProfile? matchingProfile;
    for (final item in existing) {
      if (item.name == normalizedName) {
        matchingProfile = item;
        break;
      }
    }

    final args = <String, String>{
      'name': normalizedName,
      'rate-limit': rateLimit.trim(),
      'on-login': onLogin,
      'comment': profileComment,
      'shared-users': sharedUsers.toString(),
    };

    if (matchingProfile == null) {
      await _client.command('/ip/hotspot/user/profile/add', args: args);
    } else {
      if (matchingProfile.id.isEmpty) {
        throw RouterOsException('تعذر تحديث الباقة: لم يُرجع RouterOS معرّفها.');
      }
      await _client.command(
        '/ip/hotspot/user/profile/set',
        args: <String, String>{'.id': matchingProfile.id, ...args},
      );
    }

    final updated = await fetchProfiles();
    for (final item in updated) {
      if (item.name == normalizedName) return item;
    }
    return HotspotProfile(
      id: '',
      name: normalizedName,
      rateLimit: rateLimit.trim(),
      comment: profileComment,
      validityDays: validityDays,
      validityHours: validityHours,
    );
  }

  /// The profile's on-login handler stamps first login using RouterOS' own
  /// timestamp. A single router-side scheduler checks comments every minute,
  /// disables expired users, and removes active sessions. Batch comments are
  /// retained so that generated vouchers can still be filtered by their batch.
  static String buildExpiryOnLoginScript(String validity) {
    final safeValidity = _validateRouterOsDuration(validity);
    return r'''
:local u $user;
:local uid [/ip hotspot user find where name=$u];
:if ([:len $uid] > 0) do={
  :local oldComment [/ip hotspot user get $uid comment];
  :if ([:find $oldComment "NOVA_EXP_TS="] = nil) do={
    :local validity "''' +
        safeValidity +
        r'''";
    :local expiresAt ([:timestamp] + [:totime $validity]);
    :local firstLogin ( [/system clock get date] . "_" . [/system clock get time] );
    :local expiryMarker ("NOVA_FIRST=" . $firstLogin . "|NOVA_VALID=" . $validity . "|NOVA_EXP_TS=" . $expiresAt);
    :if ([:len $oldComment] > 0) do={ :set expiryMarker ($oldComment . "|" . $expiryMarker); }
    /ip hotspot user set $uid comment=$expiryMarker;
  }
}
:if ([:len [/system scheduler find where name="NOVA-Hotspot-Expiry"]] = 0) do={
  /system scheduler add name="NOVA-Hotspot-Expiry" start-date=[/system clock get date] start-time=[/system clock get time] interval=1m comment="NOVA managed HotSpot expiry monitor" on-event=":foreach uid in=[/ip hotspot user find] do={ :local c [/ip hotspot user get $uid comment]; :local p [:find $c \"NOVA_EXP_TS=\"]; :if (($p != nil) && ([:find $c \"NOVA_EXPIRED\"] = nil)) do={ :local e [:totime [:pick $c ($p + 12) [:len $c]]]; :if ([:timestamp] >= $e) do={ :local n [/ip hotspot user get $uid name]; /ip hotspot user disable $uid; /ip hotspot user set $uid comment=($c . \"|NOVA_EXPIRED\"); /ip hotspot active remove [find where user=$n]; } } }"
}
''';
  }

  Future<List<HotspotActiveSession>> fetchActiveSessions() async {
    final rows = await _client.command(
      '/ip/hotspot/active/print',
      args: const <String, String>{
        '.proplist': '.id,user,address,mac-address,server,uptime,bytes-in,bytes-out,login-by',
      },
    );
    return rows.map(HotspotActiveSession.fromMap).toList(growable: false);
  }

  Future<void> kickActiveSession(String id) async {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id', 'معرّف الجلسة مطلوب.');
    await _client.command('/ip/hotspot/active/remove', args: <String, String>{'.id': id});
  }

  Future<List<HotspotUser>> fetchUsers() async {
    final rows = await _client.command(
      '/ip/hotspot/user/print',
      args: const <String, String>{
        '.proplist': '.id,name,profile,comment,disabled,limit-uptime,limit-bytes-total',
      },
    );
    return rows.map(HotspotUser.fromMap).toList(growable: false);
  }

  Future<void> deleteUser(String id) async {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id', 'معرّف الكرت مطلوب.');
    await _client.command('/ip/hotspot/user/remove', args: <String, String>{'.id': id});
  }

  Future<int> deleteExpiredUsers() async {
    final users = await fetchUsers();
    final expired = users.where((user) => user.isExpired && user.id.isNotEmpty).toList(growable: false);
    for (final user in expired) {
      await deleteUser(user.id);
    }
    return expired.length;
  }

  Future<List<HotspotVoucher>> generateVoucherBatch(VoucherBatchRequest request) async {
    if (request.count < 1 || request.count > 500) {
      throw ArgumentError.value(request.count, 'count', 'عدد الكروت يجب أن يكون بين 1 و500.');
    }
    if (request.codeLength < 4 || request.codeLength > 24) {
      throw ArgumentError.value(request.codeLength, 'codeLength', 'طول الكود يجب أن يكون بين 4 و24.');
    }
    if (request.profileName.trim().isEmpty) {
      throw ArgumentError.value(request.profileName, 'profileName', 'اختر باقة أولًا.');
    }
    if (request.limitBytesTotal < 0) {
      throw ArgumentError.value(request.limitBytesTotal, 'limitBytesTotal', 'حجم البيانات غير صحيح.');
    }
    if (request.limitUptime.trim().isNotEmpty) _validateRouterOsDuration(request.limitUptime);

    final prefix = request.prefix.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9_-]{0,12}    final batchId = request.batchId.trim().isEmpty
        ? DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9A-Za-z]'), '').substring(0, 14)
        : request.batchId.trim();
    final existingUsers = await fetchUsers();
    final reservedNames = existingUsers.map((user) => user.username).toSet();
    final vouchers = <HotspotVoucher>[];
    final createdNames = <String>[];
    final addArgs = <Map<String, String>>[];

    for (var index = 0; index < request.count; index++) {
      final username = _makeUniqueCode(prefix, request.codeLength, reservedNames);
      reservedNames.add(username);
      final password = request.credentialMode == HotspotCredentialMode.usernameAndPassword
          ? _makeUniqueCode('', request.codeLength, reservedNames)
          : '';
      if (password.isNotEmpty) reservedNames.add(password);

      final commentParts = <String>[
        'NOVA-BATCH=' + batchId,
        'NOVA-PRICE=' + request.price.trim(),
        if (request.validityLabel.trim().isNotEmpty) 'NOVA-VALIDITY=' + request.validityLabel.trim(),
        if (request.comment.trim().isNotEmpty) request.comment.trim(),
      ];
      final args = <String, String>{
        'name': username,
        'profile': request.profileName.trim(),
        'comment': commentParts.join('|'),
      };
      if (request.credentialMode == HotspotCredentialMode.usernameAndPassword) args['password'] = password;
      if (request.limitBytesTotal > 0) args['limit-bytes-total'] = request.limitBytesTotal.toString();
      if (request.limitUptime.trim().isNotEmpty) args['limit-uptime'] = request.limitUptime.trim();
      addArgs.add(args);
      vouchers.add(HotspotVoucher(
        username: username,
        password: password,
        profile: request.profileName.trim(),
        batchId: batchId,
        validityLabel: request.validityLabel.trim(),
        price: request.price.trim(),
        comment: commentParts.join('|'),
        limitUptime: request.limitUptime.trim(),
        limitBytesTotal: request.limitBytesTotal,
      ));
    }

    try {
      for (final args in addArgs) {
        await _client.command('/ip/hotspot/user/add', args: args);
        createdNames.add(args['name']!);
      }
    } catch (error) {
      await _rollbackUsersByName(createdNames);
      throw RouterOsException(
        'توقفت عملية التوليد بعد إضافة ' +
            createdNames.length.toString() +
            ' من ' +
            request.count.toString() +
            ' كرتًا. تمت محاولة التراجع عن الكروت المضافة. السبب: ' +
            error.toString(),
      );
    }
    return List<HotspotVoucher>.unmodifiable(vouchers);
  }

  Future<void> _rollbackUsersByName(List<String> names) async {
    if (names.isEmpty) return;
    try {
      final users = await fetchUsers();
      final targetNames = names.toSet();
      final targets = users.where((user) => targetNames.contains(user.username) && user.id.isNotEmpty);
      for (final user in targets) {
        try {
          await deleteUser(user.id);
        } catch (_) {}
      }
    } catch (_) {}
  }

  String _makeUniqueCode(String prefix, int length, Set<String> reserved) {
    final remaining = _max(0, length - prefix.length);
    for (var attempt = 0; attempt < 1000; attempt++) {
      final code = prefix + List<String>.generate(
        remaining,
        (_) => _characterSet[_random.nextInt(_characterSet.length)],
        growable: false,
      ).join();
      if (!reserved.contains(code)) return code;
    }
    throw StateError('تعذر توليد كود فريد. غيّر البادئة أو طول الكود وحاول مجددًا.');
  }

  static int _max(int a, int b) => a > b ? a : b;

  static String _formatValidity(int days, int hours) {
    final parts = <String>[];
    if (days > 0) parts.add(days.toString() + 'd');
    if (hours > 0) parts.add(hours.toString() + 'h');
    return parts.join();
  }

  static String _validateRouterOsDuration(String duration) {
    final normalized = duration.trim();
    if (!RegExp(r'^(?=.*\d)(?:\d+w)?(?:\d+d)?(?:\d+h)?(?:\d+m)?(?:\d+s)?$').hasMatch(normalized) ||
        !RegExp(r'\d').hasMatch(normalized)) {
      throw ArgumentError.value(duration, 'duration', 'استخدم مدة RouterOS مثل 2h أو 1d12h.');
    }
    return normalized;
  }
}
).hasMatch(prefix)) {
      throw ArgumentError.value(request.prefix, 'prefix', 'البادئة تقبل الأحرف الإنجليزية والأرقام و-_ فقط.');
    }
    if (prefix.length > request.codeLength) {
      throw ArgumentError.value(request.prefix, 'prefix', 'طول البادئة لا يمكن أن يتجاوز طول الكود.');
    }
    final batchId = request.batchId.trim().isEmpty
        ? DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[^0-9A-Za-z]'), '').substring(0, 14)
        : request.batchId.trim();
    final existingUsers = await fetchUsers();
    final reservedNames = existingUsers.map((user) => user.username).toSet();
    final vouchers = <HotspotVoucher>[];
    final createdNames = <String>[];
    final addArgs = <Map<String, String>>[];

    for (var index = 0; index < request.count; index++) {
      final username = _makeUniqueCode(prefix, request.codeLength, reservedNames);
      reservedNames.add(username);
      final password = request.credentialMode == HotspotCredentialMode.usernameAndPassword
          ? _makeUniqueCode('', request.codeLength, reservedNames)
          : '';
      if (password.isNotEmpty) reservedNames.add(password);

      final commentParts = <String>[
        'NOVA-BATCH=' + batchId,
        'NOVA-PRICE=' + request.price.trim(),
        if (request.validityLabel.trim().isNotEmpty) 'NOVA-VALIDITY=' + request.validityLabel.trim(),
        if (request.comment.trim().isNotEmpty) request.comment.trim(),
      ];
      final args = <String, String>{
        'name': username,
        'profile': request.profileName.trim(),
        'comment': commentParts.join('|'),
      };
      if (request.credentialMode == HotspotCredentialMode.usernameAndPassword) args['password'] = password;
      if (request.limitBytesTotal > 0) args['limit-bytes-total'] = request.limitBytesTotal.toString();
      if (request.limitUptime.trim().isNotEmpty) args['limit-uptime'] = request.limitUptime.trim();
      addArgs.add(args);
      vouchers.add(HotspotVoucher(
        username: username,
        password: password,
        profile: request.profileName.trim(),
        batchId: batchId,
        validityLabel: request.validityLabel.trim(),
        price: request.price.trim(),
        comment: commentParts.join('|'),
        limitUptime: request.limitUptime.trim(),
        limitBytesTotal: request.limitBytesTotal,
      ));
    }

    try {
      for (final args in addArgs) {
        await _client.command('/ip/hotspot/user/add', args: args);
        createdNames.add(args['name']!);
      }
    } catch (error) {
      await _rollbackUsersByName(createdNames);
      throw RouterOsException(
        'توقفت عملية التوليد بعد إضافة ' +
            createdNames.length.toString() +
            ' من ' +
            request.count.toString() +
            ' كرتًا. تمت محاولة التراجع عن الكروت المضافة. السبب: ' +
            error.toString(),
      );
    }
    return List<HotspotVoucher>.unmodifiable(vouchers);
  }

  Future<void> _rollbackUsersByName(List<String> names) async {
    if (names.isEmpty) return;
    try {
      final users = await fetchUsers();
      final targetNames = names.toSet();
      final targets = users.where((user) => targetNames.contains(user.username) && user.id.isNotEmpty);
      for (final user in targets) {
        try {
          await deleteUser(user.id);
        } catch (_) {}
      }
    } catch (_) {}
  }

  String _makeUniqueCode(String prefix, int length, Set<String> reserved) {
    final remaining = _max(0, length - prefix.length);
    for (var attempt = 0; attempt < 1000; attempt++) {
      final code = prefix + List<String>.generate(
        remaining,
        (_) => _characterSet[_random.nextInt(_characterSet.length)],
        growable: false,
      ).join();
      if (!reserved.contains(code)) return code;
    }
    throw StateError('تعذر توليد كود فريد. غيّر البادئة أو طول الكود وحاول مجددًا.');
  }

  static int _max(int a, int b) => a > b ? a : b;

  static String _formatValidity(int days, int hours) {
    final parts = <String>[];
    if (days > 0) parts.add(days.toString() + 'd');
    if (hours > 0) parts.add(hours.toString() + 'h');
    return parts.join();
  }

  static String _validateRouterOsDuration(String duration) {
    final normalized = duration.trim();
    if (!RegExp(r'^(?=.*\d)(?:\d+w)?(?:\d+d)?(?:\d+h)?(?:\d+m)?(?:\d+s)?$').hasMatch(normalized) ||
        !RegExp(r'\d').hasMatch(normalized)) {
      throw ArgumentError.value(duration, 'duration', 'استخدم مدة RouterOS مثل 2h أو 1d12h.');
    }
    return normalized;
  }
}
