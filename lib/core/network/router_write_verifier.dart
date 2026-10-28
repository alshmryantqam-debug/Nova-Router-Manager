import 'dart:async';
import 'router_error.dart';

enum VerifiedOperation { add, set, remove, bulk, unobservable }
enum VerifiedWriteState { running, confirmed, sentUnconfirmed, failed }

class VerifiedWriteResult {
  const VerifiedWriteResult(this.state, {this.message = '', this.value});
  final VerifiedWriteState state;
  final String message;
  final Object? value;
  bool get isConfirmed => state == VerifiedWriteState.confirmed;
}

typedef ReadObject = Future<Map<String, String>?> Function();
typedef WriteCommand = Future<Object?> Function();

/// Executes one mutation and checks a fresh read. A timeout is ambiguous:
/// read back first and never replay an add automatically.
Future<VerifiedWriteResult> runVerified({
  required VerifiedOperation operation,
  required WriteCommand write,
  required ReadObject readBack,
  Map<String, String> expected = const {},
  Map<String, String> previous = const {},
  Duration timeout = const Duration(seconds: 20),
  String label = 'التغيير',
}) async {
  try {
    final writeValue = await write().timeout(timeout);
    if (operation == VerifiedOperation.unobservable) {
      return VerifiedWriteResult(VerifiedWriteState.sentUnconfirmed, message: 'أُرسل الأمر؛ لا توجد قراءة آمنة تؤكد تنفيذه.', value: writeValue);
    }
    final actual = await readBack().timeout(timeout);
    if (_matches(operation, actual, expected, previous)) {
      return VerifiedWriteResult(VerifiedWriteState.confirmed, message: 'تم تأكيد $label بقراءة جديدة من الراوتر.', value: actual ?? writeValue);
    }
    return VerifiedWriteResult(VerifiedWriteState.failed, message: 'لم تتطابق الحالة المقروءة مع التغيير المطلوب؛ لم يُعرض نجاح.', value: actual);
  } on TimeoutException {
    try {
      final actual = await readBack().timeout(timeout);
      if (_matches(operation, actual, expected, previous)) return VerifiedWriteResult(VerifiedWriteState.confirmed, message: 'انتهت المهلة، لكن القراءة الجديدة أكدت تطبيق $label.', value: actual);
      return VerifiedWriteResult(VerifiedWriteState.sentUnconfirmed, message: 'انتهت المهلة؛ أُرسل الأمر لكن لم يمكن تأكيده. لم تتم إعادة إرساله.', value: actual);
    } catch (readError) {
      return VerifiedWriteResult(VerifiedWriteState.sentUnconfirmed, message: 'انتهت المهلة وتعذرت قراءة الحالة. أُرسل الأمر دون تأكيد؛ لا تعاود الإضافة تلقائياً.', value: RouterError.from(readError));
    }
  } catch (error) {
    final mapped = RouterError.from(error);
    return VerifiedWriteResult(VerifiedWriteState.failed, message: mapped.toString(), value: mapped);
  }
}

bool _matches(VerifiedOperation operation, Map<String, String>? actual, Map<String, String> expected, Map<String, String> previous) {
  if (operation == VerifiedOperation.remove) return actual == null;
  if (actual == null) return false;
  if (operation == VerifiedOperation.set && previous.isNotEmpty && previous.entries.every((e) => _normalize(actual[e.key]) == _normalize(e.value))) return false;
  return expected.entries.every((entry) => _normalize(actual[entry.key]) == _normalize(entry.value));
}

String? _normalize(String? value) {
  if (value == null) return null;
  final clean = value.trim().toLowerCase();
  if (clean == 'yes' || clean == 'true' || clean == '1') return 'true';
  if (clean == 'no' || clean == 'false' || clean == '0') return 'false';
  return clean;
}
