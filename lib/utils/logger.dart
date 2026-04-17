import 'dart:developer' as developer;

/// Structured logger with:
///   • ISO-8601 timestamps on every line
///   • Named subsystem tags for easy grep (BLE, WiFiDirect, Mesh, DTN, Broadcast …)
///   • Per-message throttle — identical messages are suppressed for
///     [_throttleMs] milliseconds so rapid loops don't flood the log
///   • Four levels: debug / info / warning / error
///
/// Usage:
///   Logger.info('Peer discovered', tag: Logger.ble);
///   Logger.warning('No route found', tag: Logger.mesh);
///   Logger.error('Socket closed', e, tag: Logger.wifi);
class Logger {
  // ── Subsystem tags ────────────────────────────────────────────────────────
  static const String ble       = 'BLE';
  static const String wifi      = 'WiFiDirect';
  static const String mesh      = 'Mesh';
  static const String dtn       = 'DTN';
  static const String broadcast = 'Broadcast';
  static const String conn      = 'Connection';
  static const String scan      = 'Scan';
  static const String advert    = 'Advertise';
  static const String hopping   = 'Hop';
  static const String general   = 'OFFLINK';

  // ── Throttle config ───────────────────────────────────────────────────────
  /// Suppress the exact same log message if it was already emitted within
  /// this window.  Prevents loop-driven spam without losing novel events.
  static const int _throttleMs = 5000;

  /// Maps message → last-emitted timestamp (epoch ms).
  static final Map<String, int> _lastEmit = {};

  static bool _isThrottled(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastEmit[key];
    if (last != null && (now - last) < _throttleMs) return true;
    _lastEmit[key] = now;
    // Keep the map bounded — evict entries older than 60 s
    if (_lastEmit.length > 200) {
      final cutoff = now - 60000;
      _lastEmit.removeWhere((_, ts) => ts < cutoff);
    }
    return false;
  }

  static String _ts() {
    final t = DateTime.now();
    final h  = t.hour.toString().padLeft(2, '0');
    final m  = t.minute.toString().padLeft(2, '0');
    final s  = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  // ── Public API ────────────────────────────────────────────────────────────

  static void debug(String message, {String? tag, bool throttle = true}) {
    final key = '${tag ?? general}|$message';
    if (throttle && _isThrottled(key)) return;
    developer.log(
      '[${_ts()}] $message',
      name: tag ?? general,
      level: 700,
    );
  }

  static void info(String message, {String? tag, bool throttle = false}) {
    final key = '${tag ?? general}|$message';
    if (throttle && _isThrottled(key)) return;
    developer.log(
      '[${_ts()}] $message',
      name: tag ?? general,
      level: 800,
    );
  }

  static void warning(String message, {String? tag, bool throttle = false}) {
    final key = '${tag ?? general}|$message';
    if (throttle && _isThrottled(key)) return;
    developer.log(
      '[${_ts()}] $message',
      name: tag ?? general,
      level: 900,
    );
  }

  static void error(
    String message, [
    Object? error,
    StackTrace? stackTrace,
    String? tag,
  ]) {
    developer.log(
      '[${_ts()}] $message',
      name: tag ?? general,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
