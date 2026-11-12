import 'package:flutter/foundation.dart';

/// In-memory error log (last 200 entries). Errors that used to be swallowed
/// end up here, and Settings can copy them so problems seen on a real device
/// can be pasted into a bug report.
class AppLog {
  static final _lines = <String>[];
  static final changes = ValueNotifier<int>(0);

  static String _now() => DateTime.now().toIso8601String().substring(11, 19);

  static void error(String where, Object e, [StackTrace? s]) {
    final st = s == null
        ? ''
        : '\n${s.toString().split('\n').take(4).join('\n')}';
    _add('[${_now()}] $where: $e$st');
  }

  static void info(String msg) => _add('[${_now()}] $msg');

  /// Host + path only. Query strings and fragments on sign-in / player pages
  /// can carry session identifiers, so they never reach the log.
  static String redactUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return '[unparseable url]';
    return '${u.scheme}://${u.host}${u.path}';
  }

  static String _sanitize(String msg) {
    // Redact cookies and sensitive tokens from logs so they cannot be leaked in bug reports
    return msg
        .replaceAllMapped(
          RegExp(r'(SAPISID|APISID|SSID|HSID|SID|LOGIN_INFO|__Secure-[^=]+)=[^; \n]+', caseSensitive: false),
          (m) => '${m.group(1)}=[REDACTED]',
        )
        .replaceAllMapped(
          RegExp(r'(poToken|token|sig|lsig|access_token|api_key|key|visitor_?data|secret|password)=[^&\s\n]+', caseSensitive: false),
          (m) => '${m.group(1)}=[REDACTED]',
        )
        .replaceAll(
          RegExp(r'(Bearer|Basic)\s+[A-Za-z0-9._~+/-]+=*', caseSensitive: false),
          r'$1 [REDACTED]',
        );
  }

  static void _add(String line) {
    final safe = _sanitize(line);
    _lines.add(safe);
    if (_lines.length > 200) _lines.removeAt(0);
    changes.value++;
    debugPrint(safe);
  }

  static String get text => _lines.join('\n');
  static int get length => _lines.length;

  static void clear() {
    _lines.clear();
    changes.value++;
  }
}
