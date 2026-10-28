import 'dart:async';

import 'routeros_client.dart';

/// Sends a single mutation and confirms its result with a fresh RouterOS read.
/// It never retries a write after a timeout, because the first write may have
/// reached the router even when its response was lost.
extension VerifiedRouterOsCommands on RouterOsClient {
  Future<void> verifiedCommand(
    String path, {
    Map<String, String> args = const <String, String>{},
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final parts = path.split('/');
    final action = parts.removeLast();
    final base = parts.join('/');
    if (!const <String>{'add', 'set', 'remove', 'enable', 'disable'}.contains(action)) {
      throw ArgumentError.value(path, 'path', 'Unsupported verified mutation');
    }
    final id = args['.id'] ?? args['numbers'] ?? args['id'];
    if (action != 'add' && (id == null || id.isEmpty)) {
      throw ArgumentError('A RouterOS item ID is required for $action.');
    }
    final expected = <String, String>{...args}
      ..remove('.id')
      ..remove('numbers')
      ..remove('id');
    if (action == 'enable') expected['disabled'] = 'false';
    if (action == 'disable') expected['disabled'] = 'true';
    if (action == 'add' && path == '/ip/firewall/address-list/add') expected.remove('timeout');
    if (action == 'add' && expected.isEmpty) {
      throw ArgumentError('Verified add requires fields to identify the new object.');
    }

    Object? writeError;
    final writePath = action == 'enable' || action == 'disable' ? '$base/set' : path;
    final writeArgs = <String, String>{...args};
    if (action == 'enable') writeArgs['disabled'] = 'false';
    if (action == 'disable') writeArgs['disabled'] = 'true';
    try {
      await command(writePath, args: writeArgs, timeout: timeout);
    } catch (error) {
      if (error is TimeoutException) {
        writeError = error;
      } else {
        rethrow;
      }
    }

    final rows = await command('$base/print', args: const <String, String>{}, timeout: timeout);
    bool matches(Map<String, String> row) => expected.entries.every((entry) {
      final actual = (row[entry.key] ?? '').trim().toLowerCase();
      final wanted = entry.value.trim().toLowerCase();
      if (actual.isEmpty && wanted.isEmpty) return true;
      if (const <String>{'yes', 'true', '1'}.contains(actual) &&
          const <String>{'yes', 'true', '1'}.contains(wanted)) return true;
      if (const <String>{'no', 'false', '0'}.contains(actual) &&
          const <String>{'no', 'false', '0'}.contains(wanted)) return true;
      return actual == wanted;
    });

    if (action == 'remove') {
      if (rows.any((row) => row['.id'] == id)) {
        throw StateError('أُرسل أمر الحذف لكن القراءة الجديدة ما زالت تعرض العنصر؛ لم يتم تأكيد الحذف.');
      }
      return;
    }

    if (action == 'set' || action == 'enable' || action == 'disable') {
      final row = rows.where((row) => row['.id'] == id).firstOrNull;
      if (row == null || !matches(row)) {
        throw StateError('لم تؤكد القراءة الجديدة تطبيق التغيير على العنصر $id.');
      }
      return;
    }

    // For an add with no returned ID, require exactly one object matching all
    // requested fields; ambiguous duplicates are deliberately not reported as success.
    final found = rows.where(matches).toList(growable: false);
    if (found.length != 1) {
      throw StateError(found.isEmpty
          ? 'أُرسل أمر الإضافة لكن لم يظهر عنصر مطابق في القراءة الجديدة.'
          : 'تعذر تأكيد الإضافة بسبب وجود أكثر من عنصر مطابق؛ راجع القائمة قبل إعادة المحاولة.');
    }
    if (writeError != null) return; // Read-back confirmed despite lost response.
  }
}
