import 'dart:async';

import '../../core/network/routeros_client.dart';

/// A live, unified view of a PPPoE secret, its active session and its dynamic
/// simple queue. All mutations are sent to the connected RouterOS router.
class PppoeSubscriber {
  const PppoeSubscriber({
    required this.id,
    required this.name,
    required this.profile,
    required this.disabled,
    required this.comment,
    required this.callerId,
    required this.online,
    required this.address,
    required this.activeId,
    required this.uptime,
    required this.sessionRxBytes,
    required this.sessionTxBytes,
    required this.rxMbps,
    required this.txMbps,
    required this.lastLoggedOut,
    required this.lastDisconnectReason,
    required this.queueId,
    required this.queueName,
    required this.maxLimit,
  });

  final String id;
  final String name;
  final String profile;
  final bool disabled;
  final String comment;
  final String callerId;
  final bool online;
  final String address;
  final String activeId;
  final String uptime;
  final int sessionRxBytes;
  final int sessionTxBytes;
  final double rxMbps;
  final double txMbps;
  final String lastLoggedOut;
  final String lastDisconnectReason;
  final String queueId;
  final String queueName;
  final String maxLimit;

  DateTime? get expiry {
    final match = RegExp(r'(?:^|\\s)EXP:(\\d{4}-\\d{2}-\\d{2})').firstMatch(comment);
    if (match == null) return null;
    return DateTime.tryParse(match.group(1)!);
  }

  bool get expired {
    final value = expiry;
    if (value == null) return false;
    final today = DateTime.now();
    return DateTime(value.year, value.month, value.day)
        .isBefore(DateTime(today.year, today.month, today.day));
  }

  bool get macLocked => callerId.trim().isNotEmpty;

  static int _integer(String? value) {
    if (value == null) return 0;
    final clean = value.replaceAll(RegExp(r'[^0-9]'), '');
    return int.tryParse(clean) ?? 0;
  }

  static double _rateMbps(String? value) {
    final number = _integer(value);
    return number * 8 / 1000000;
  }

  factory PppoeSubscriber.fromRows({
    required Map<String, String> secret,
    Map<String, String>? active,
    Map<String, String>? queue,
  }) {
    final rate = (queue?['rate'] ?? '0/0').split('/');
    final rx = rate.length > 1 ? _rateMbps(rate[1]) : 0.0;
    final tx = rate.isNotEmpty ? _rateMbps(rate[0]) : 0.0;
    final comment = secret['comment'] ?? '';
    return PppoeSubscriber(
      id: secret['.id'] ?? '',
      name: secret['name'] ?? '',
      profile: secret['profile'] ?? 'default',
      disabled: secret['disabled'] == 'true',
      comment: comment,
      callerId: (active?['caller-id'] ?? secret['caller-id'] ?? ''),
      online: active != null,
      address: active?['address'] ?? '',
      activeId: active?['.id'] ?? '',
      uptime: active?['uptime'] ?? '',
      sessionRxBytes: _integer(active?['bytes-out']),
      sessionTxBytes: _integer(active?['bytes-in']),
      rxMbps: rx,
      txMbps: tx,
      lastLoggedOut: secret['last-logged-out'] ?? '',
      lastDisconnectReason: secret['last-disconnect-reason'] ?? '',
      queueId: queue?['.id'] ?? '',
      queueName: queue?['name'] ?? '',
      maxLimit: queue?['max-limit'] ?? '',
    );
  }
}

class PppoeProService {
  const PppoeProService(this.client);

  final RouterOsClient client;

  Future<List<PppoeSubscriber>> loadSubscribers() async {
    final result = await Future.wait<List<Map<String, String>>>([
      client.command('/ppp/secret/print', args: const {
        '.proplist': '.id,name,profile,disabled,comment,caller-id,last-logged-out,last-disconnect-reason',
      }),
      client.command('/ppp/active/print', args: const {
        '.proplist': '.id,name,address,uptime,service,caller-id,bytes-in,bytes-out',
      }),
      client.command('/queue/simple/print', args: const {
        '.proplist': '.id,name,dynamic,rate,max-limit,bytes',
      }),
    ]);

    final activeByName = <String, Map<String, String>>{};
    for (final row in result[1]) {
      final name = row['name'];
      if (name != null && name.isNotEmpty) activeByName[name] = row;
    }
    final queueByName = <String, Map<String, String>>{};
    for (final row in result[2]) {
      final name = row['name'] ?? '';
      // RouterOS names the dynamic PPP queue <pppoe-username>.
      if (name.startsWith('<pppoe-') && name.endsWith('>')) {
        queueByName[name.substring(7, name.length - 1)] = row;
      }
    }

    final subscribers = result[0]
        .where((row) => (row['name'] ?? '').isNotEmpty)
        .map((secret) {
          final name = secret['name']!;
          return PppoeSubscriber.fromRows(
            secret: secret,
            active: activeByName[name],
            queue: queueByName[name],
          );
        })
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return subscribers;
  }

  Future<List<String>> loadProfiles() async {
    final rows = await client.command('/ppp/profile/print', args: const {'.proplist': 'name'});
    return rows.map((row) => row['name'] ?? '').where((name) => name.isNotEmpty).toSet().toList()..sort();
  }

  Future<void> changeProfile(PppoeSubscriber subscriber, String profile) async {
    _requireId(subscriber.id);
    await client.command('/ppp/secret/set', args: {'.id': subscriber.id, 'profile': profile});
  }

  Future<void> lockToCurrentDevice(PppoeSubscriber subscriber) async {
    _requireId(subscriber.id);
    if (!subscriber.online || subscriber.activeId.isEmpty || subscriber.callerId.trim().isEmpty) {
      throw StateError('المشترك غير متصل أو لم يُرجع الراوتر Caller-ID صالحًا.');
    }
    await client.command('/ppp/secret/set', args: {
      '.id': subscriber.id,
      'caller-id': subscriber.callerId.trim(),
    });
  }

  Future<void> resetCallerId(PppoeSubscriber subscriber) async {
    _requireId(subscriber.id);
    await client.command('/ppp/secret/set', args: {'.id': subscriber.id, 'caller-id': ''});
  }

  /// Updates the dynamic queue's max-limit without removing the PPP session.
  /// RouterOS max-limit order is upload/download, in bits per second.
  Future<void> setLiveSpeed(
    PppoeSubscriber subscriber, {
    required double uploadMbps,
    required double downloadMbps,
  }) async {
    if (!subscriber.online || subscriber.queueId.isEmpty) {
      throw StateError('لا يوجد طابور ديناميكي للمشترك المتصل؛ لم يتم فصل الجلسة أو تغييرها.');
    }
    if (uploadMbps <= 0 || downloadMbps <= 0 || uploadMbps > 10000 || downloadMbps > 10000) {
      throw ArgumentError('أدخل سرعة أكبر من صفر ولا تتجاوز 10000 Mbps.');
    }
    await client.command('/queue/simple/set', args: {
      '.id': subscriber.queueId,
      'max-limit': '${_limit(uploadMbps)}/${_limit(downloadMbps)}',
    });
  }

  String _limit(double mbps) => mbps == mbps.roundToDouble()
      ? '${mbps.toInt()}M'
      : '${mbps.toStringAsFixed(2)}M';

  Future<void> disconnect(PppoeSubscriber subscriber) async {
    if (subscriber.activeId.isEmpty) throw StateError('المشترك غير متصل حاليًا.');
    await client.command('/ppp/active/remove', args: {'.id': subscriber.activeId});
  }

  Future<List<Map<String, String>>> ping(String address) async {
    if (address.trim().isEmpty) throw StateError('لا يوجد IP حالي للمشترك.');
    return client.command('/ping', args: {'address': address.trim(), 'count': '4', 'interval': '300ms'});
  }

  Future<void> renewOneMonth(PppoeSubscriber subscriber) async {
    _requireId(subscriber.id);
    final now = DateTime.now();
    final current = subscriber.expiry;
    final base = current != null && !current.isBefore(DateTime(now.year, now.month, now.day))
        ? current
        : now;
    final next = DateTime(base.year, base.month + 1, base.day);
    final date = '${next.year.toString().padLeft(4, '0')}-${next.month.toString().padLeft(2, '0')}-${next.day.toString().padLeft(2, '0')}';
    final withoutExpiry = subscriber.comment.replaceAll(RegExp(r'(?:^|\\s)EXP:\\d{4}-\\d{2}-\\d{2}'), '').trim();
    final comment = [if (withoutExpiry.isNotEmpty) withoutExpiry, 'EXP:$date'].join(' ');
    await client.command('/ppp/secret/set', args: {'.id': subscriber.id, 'comment': comment});
  }

  Future<void> setIsolationProfile(PppoeSubscriber subscriber, String profile) =>
      changeProfile(subscriber, profile);

  static void _requireId(String id) {
    if (id.isEmpty) throw StateError('معرّف حساب PPPoE غير متوفر.');
  }
}
