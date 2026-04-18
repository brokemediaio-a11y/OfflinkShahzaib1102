import 'dart:developer' as developer;

/// Structured logger with:
///   • HH:mm:ss.SSS timestamp on every line
///   • Named subsystem tags for easy filtering (BLE, WiFiDirect, Mesh, DTN, …)
///   • Per-message throttle — identical (tag + message) pairs are suppressed
///     for [_throttleMs] milliseconds so rapid poll loops don't flood the log
///   • Four severity levels: debug / info / warning / error
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

  static void debug(String message, [String? tag, bool throttle = true]) {
    final subsystem = tag ?? 'OFFLINK';
    final key = '$subsystem|$message';
    if (!_shouldEmit(key, throttle: throttle)) return;
    developer.log(
      '[${_ts()}] $message',
      name: subsystem,
      level: 700,
    );
  }

  static void info(String message, [String? tag]) {
    developer.log(
      '[${_ts()}] $message',
      name: tag ?? 'OFFLINK',
      level: 800,
    );
  }

  static void warning(String message, [String? tag]) {
    developer.log(
      '[${_ts()}] ⚠️ $message',
      name: tag ?? 'OFFLINK',
      level: 900,
    );
  }

  static void error(String message, [Object? error, StackTrace? stackTrace, String? tag]) {
    developer.log(
      '[${_ts()}] ❌ $message',
      name: tag ?? 'OFFLINK',
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// Throttled info — emits at info level but suppresses duplicates within [_throttleMs].
  static void throttled(String message, [String? tag]) {
    final subsystem = tag ?? 'OFFLINK';
    final key = '$subsystem|$message';
    if (!_shouldEmit(key, throttle: true)) return;
    developer.log(
      '[${_ts()}] $message',
      name: subsystem,
      level: 800,
    );
  }

  // ── Specialised emoji logs for hop/relay/DTN events ───────────────────────
  // Use these instead of info() for mesh events so they stand out visually
  // in the debug console and can be filtered with a single keyword search.

  /// 🔁  Relay hop event — packet forwarded to next peer.
  static void hop(String message) {
    developer.log(
      '[${_ts()}] 🔁 $message',
      name: hopping,
      level: 800,
    );
  }

  /// 📬  Local delivery — packet arrived at its final destination on this device.
  static void deliver(String message) {
    developer.log(
      '[${_ts()}] 📬 $message',
      name: mesh,
      level: 800,
    );
  }

  /// 📦  DTN store-and-forward event — packet queued or retried.
  static void dtnLog(String message) {
    developer.log(
      '[${_ts()}] 📦 $message',
      name: dtn,
      level: 800,
    );
  }

  /// ✅  Successful DTN delivery — packet confirmed received after relay.
  static void dtnDelivered(String message) {
    developer.log(
      '[${_ts()}] ✅ $message',
      name: dtn,
      level: 800,
    );
  }

  /// 🔗  Connection event for relay/DTN (connect, disconnect, restore GO).
  static void relay(String message) {
    developer.log(
      '[${_ts()}] 🔗 $message',
      name: conn,
      level: 800,
    );
  }
}
