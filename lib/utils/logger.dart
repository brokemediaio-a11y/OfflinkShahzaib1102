import 'dart:developer' as developer;
import 'file_logger.dart';

/// Structured logger with:
///   • HH:mm:ss.SSS timestamp on every line
///   • Named subsystem tags for easy filtering (BLE, WiFiDirect, Mesh, DTN, …)
///   • Per-message throttle — identical (tag + message) pairs are suppressed
///     for [_throttleMs] milliseconds so rapid poll loops don't flood the log
///   • Four severity levels: debug / info / warning / error
///   • File sink (hop-test branch) — every call is also written to a .log file
///     on device storage via [FileLogger]. Pull with:
///       adb pull /sdcard/Android/data/com.offlink.app/files/logs/
class Logger {
  // ── Subsystem tag constants ────────────────────────────────────────────────
  static const String ble       = 'BLE';
  static const String wifi      = 'WiFiDirect';
  static const String mesh      = 'Mesh';
  static const String dtn       = 'DTN';
  static const String broadcast = 'Broadcast';
  static const String conn      = 'Conn';
  static const String scan      = 'Scan';
  static const String advert    = 'Advert';
  static const String hopping   = 'Hopping';

  // ── Throttle ────────────────────────────────────────────────────────────────
  /// Suppress duplicate messages within this window (debug level only by default).
  static const int _throttleMs = 5000;
  static final Map<String, int> _lastEmitted = {};

  static String _ts() {
    final t = DateTime.now();
    final h  = t.hour.toString().padLeft(2, '0');
    final m  = t.minute.toString().padLeft(2, '0');
    final s  = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  /// Returns true and records timestamp if this message should be emitted.
  /// Returns false if it was emitted within [_throttleMs] and [throttle] is true.
  static bool _shouldEmit(String key, {bool throttle = false}) {
    if (!throttle) return true;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastEmitted[key];
    if (last != null && (now - last) < _throttleMs) return false;
    _lastEmitted[key] = now;
    return true;
  }

  // ── File sink helper ───────────────────────────────────────────────────────
  static void _toFile(String level, String tag, String message) {
    FileLogger.instance.log(level, tag, message);
  }

  // ── Log methods ───────────────────────────────────────────────────────────

  static void debug(String message, [String? tag, bool throttle = true]) {
    final subsystem = tag ?? 'OFFLINK';
    final key = '$subsystem|$message';
    if (!_shouldEmit(key, throttle: throttle)) return;
    developer.log('[${_ts()}] $message', name: subsystem, level: 700);
    _toFile('DBG', subsystem, message);
  }

  static void info(String message, [String? tag]) {
    final subsystem = tag ?? 'OFFLINK';
    developer.log('[${_ts()}] $message', name: subsystem, level: 800);
    _toFile('INF', subsystem, message);
  }

  static void warning(String message, [String? tag]) {
    final subsystem = tag ?? 'OFFLINK';
    developer.log('[${_ts()}] ⚠️ $message', name: subsystem, level: 900);
    _toFile('WRN', subsystem, message);
  }

  static void error(String message, [Object? error, StackTrace? stackTrace, String? tag]) {
    final subsystem = tag ?? 'OFFLINK';
    developer.log(
      '[${_ts()}] ❌ $message',
      name: subsystem,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
    final errStr = error != null ? ' | error=$error' : '';
    _toFile('ERR', subsystem, '$message$errStr');
  }

  /// Throttled info — emits at info level but suppresses duplicates within [_throttleMs].
  static void throttled(String message, [String? tag]) {
    final subsystem = tag ?? 'OFFLINK';
    final key = '$subsystem|$message';
    if (!_shouldEmit(key, throttle: true)) return;
    developer.log('[${_ts()}] $message', name: subsystem, level: 800);
    _toFile('INF', subsystem, message);
  }

  // ── Specialised emoji logs for hop/relay/DTN events ───────────────────────

  /// 🔁  Relay hop event — packet forwarded to next peer.
  static void hop(String message) {
    developer.log('[${_ts()}] 🔁 $message', name: hopping, level: 800);
    _toFile('HOP', hopping, message);
  }

  /// 📬  Local delivery — packet arrived at its final destination on this device.
  static void deliver(String message) {
    developer.log('[${_ts()}] 📬 $message', name: mesh, level: 800);
    _toFile('DLV', mesh, message);
  }

  /// 📦  DTN store-and-forward event — packet queued or retried.
  static void dtnLog(String message) {
    developer.log('[${_ts()}] 📦 $message', name: dtn, level: 800);
    _toFile('DTN', dtn, message);
  }

  /// ✅  Successful DTN delivery — packet confirmed received after relay.
  static void dtnDelivered(String message) {
    developer.log('[${_ts()}] ✅ $message', name: dtn, level: 800);
    _toFile('ACK', dtn, message);
  }

  /// 🔗  Connection event for relay/DTN (connect, disconnect, restore GO).
  static void relay(String message) {
    developer.log('[${_ts()}] 🔗 $message', name: conn, level: 800);
    _toFile('RLY', conn, message);
  }
}
