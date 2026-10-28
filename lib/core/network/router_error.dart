import 'dart:async';
import 'dart:io';
import 'routeros_client.dart';

enum RouterErrorKind { timeout, permission, untrustedCertificate, unsupported, routerRejected, disconnected }

class RouterError implements Exception {
  const RouterError(this.kind, this.message, this.suggestion, {this.originalText});
  final RouterErrorKind kind;
  final String message;
  final String suggestion;
  final String? originalText;

  factory RouterError.from(Object error) {
    if (error is RouterError) return error;
    if (error is TimeoutException) return RouterError(RouterErrorKind.timeout, 'انتهت مهلة الاتصال بالراوتر.', 'تحقق من الشبكة ثم أعد قراءة الحالة قبل إعادة المحاولة.', originalText: error.toString());
    if (error is HandshakeException || error is TlsException) return RouterError(RouterErrorKind.untrustedCertificate, 'شهادة TLS للراوتر غير موثوقة.', 'تحقق من الشهادة وبصمتها عبر قناة إدارية موثوقة.', originalText: error.toString());
    if (error is SocketException) return RouterError(RouterErrorKind.disconnected, 'انقطع الاتصال بالراوتر.', 'تحقق من عنوان الراوتر والمنفذ وقواعد الجدار الناري.', originalText: error.message);
    final raw = error is RouterOsException ? error.message : error.toString();
    final lower = raw.toLowerCase();
    if (RegExp(r'(^|\D)(401|403)(\D|$)').hasMatch(raw) || lower.contains('not enough permissions') || lower.contains('permission denied') || lower.contains('صلاحيات')) {
      return RouterError(RouterErrorKind.permission, 'صلاحيات حساب الراوتر غير كافية.', 'امنح الحساب أقل مجموعة صلاحيات لازمة ثم أعد المحاولة.', originalText: raw);
    }
    if (lower.contains('not supported') || lower.contains('unsupported') || lower.contains('غير مدعوم')) return RouterError(RouterErrorKind.unsupported, 'هذه العملية غير مدعومة في إصدار RouterOS المتصل.', 'استخدم إصداراً يدعم العملية أو افتح شاشة متوافقة.', originalText: raw);
    if (lower.contains('handshake') || lower.contains('certificate') || lower.contains('bad certificate')) return RouterError(RouterErrorKind.untrustedCertificate, 'شهادة TLS للراوتر غير موثوقة.', 'تحقق من الشهادة وبصمتها عبر قناة إدارية موثوقة.', originalText: raw);
    if (lower.contains('socket') || lower.contains('connection closed') || lower.contains('connection reset') || lower.contains('network is unreachable')) return RouterError(RouterErrorKind.disconnected, 'تعذر الاتصال بالراوتر أو انقطع الاتصال.', 'تحقق من الشبكة والمنفذ وحالة خدمة API/REST.', originalText: raw);
    return RouterError(RouterErrorKind.routerRejected, 'رفض الراوتر العملية.', 'راجع صلاحية الأمر وقيم الحقول في RouterOS.', originalText: raw);
  }

  @override
  String toString() => '$message $suggestion${originalText == null ? '' : '\nالتفاصيل الأصلية: $originalText'}';
}
