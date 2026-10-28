import 'dart:async';

import 'router_write_verifier.dart';
import 'routeros_client.dart';

/// Sends one mutation and confirms it with a fresh read from RouterOS.
/// Writes are never replayed after a timeout: the read-back decides whether
/// the operation completed or remains unconfirmed.
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
    final singletonSet = action == 'set' && const <String>{'/ip/dns/set', '/system/identity/set', '/ip/cloud/set'}.contains(path);
    if (action != 'add' && !singletonSet && (id == null || id.isEmpty)) {
      throw ArgumentError('A RouterOS item ID is required for $action.');
    }

    final expected = <String, String>{...args}
      ..remove('.id')
      ..remove('numbers')
      ..remove('id')
      ..remove('place-before');
    var writePath = path;
    final operation = action == 'remove'
        ? VerifiedOperation.remove
        : action == 'add'
            ? VerifiedOperation.add
            : VerifiedOperation.set;

    // RouterOS REST expresses enable/disable as a PATCH to the item resource.
    // Using /set also works with the binary API on RouterOS v6 and v7.
    if (action == 'enable' || action == 'disable') {
      writePath = '$base/set';
      expected['disabled'] = action == 'enable' ? 'false' : 'true';
    }
    if (action == 'add' && path == '/ip/firewall/address-list/add') {
      // RouterOS reports the remaining timeout, not the original duration.
      expected.remove('timeout');
    }
    if (action == 'add' && expected.isEmpty) {
      throw ArgumentError('Verified add requires fields to identify the new object.');
    }

    final result = await runVerified(
      operation: operation,
      timeout: timeout,
      label: path,
      expected: expected,
      write: () => command(writePath, args: argsForWrite(args, action), timeout: timeout),
      readBack: () async {
        final rows = await command('$base/print', timeout: timeout);
        if (action == 'remove') {
          return rows.where((row) => row['.id'] == id).firstOrNull;
        }
        if (action == 'add') {
          bool matches(Map<String, String> row) => expected.entries.every(
                (entry) => _sameRouterValue(row[entry.key], entry.value),
              );
          final found = rows.where(matches).toList(growable: false);
          if (found.length > 1) {
            throw StateError('تعذر تأكيد الإضافة لوجود أكثر من عنصر مطابق؛ راجع القائمة قبل إعادة المحاولة.');
          }
          return found.firstOrNull;
        }
        return singletonSet ? rows.firstOrNull : rows.where((row) => row['.id'] == id).firstOrNull;
      },
    );

    if (!result.isConfirmed) {
      throw StateError(result.message.isEmpty
          ? 'لم يتم تأكيد التغيير بقراءة جديدة من الراوتر.'
          : result.message);
    }
  }

  Map<String, String> argsForWrite(Map<String, String> args, String action) {
    final output = <String, String>{...args};
    if (action == 'enable') output['disabled'] = 'false';
    if (action == 'disable') output['disabled'] = 'true';
    return output;
  }
}

bool _sameRouterValue(String? actualValue, String expectedValue) {
  final actual = (actualValue ?? '').trim().toLowerCase();
  final expected = expectedValue.trim().toLowerCase();
  if (actual.isEmpty && expected.isEmpty) return true;
  if (const <String>{'yes', 'true', '1'}.contains(actual) &&
      const <String>{'yes', 'true', '1'}.contains(expected)) return true;
  if (const <String>{'no', 'false', '0'}.contains(actual) &&
      const <String>{'no', 'false', '0'}.contains(expected)) return true;
  return actual == expected;
}
