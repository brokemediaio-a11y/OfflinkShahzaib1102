import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// ──────────────────────────────────────────────────────────────────────────
/// FileLogger  (hop-test branch)
///
/// Writes every Logger call to a plain-text file on device storage so that
/// after a test run you can hand the file to the developer for analysis.
///
/// File location (Android):
///   /sdcard/Android/data/com.offlink.app/files/logs/
///   offlink_<deviceName>_<date>_<sessionTime>.log
///
/// Pull from PC:
///   adb pull /sdcard/Android/data/com.offlink.app/files/logs/
///
/// Usage:
///   await FileLogger.init(deviceName: 'A', deviceId: 'abc123…');
///   // Then Logger calls automatically write to the file.
///   // Call FileLogger.flush() before reading the file.
/// ──────────────────────────────────────────────────────────────────────────
class FileLogger {
  FileLogger._();
  static final FileLogger instance = FileLogger._();

  IOSink? _sink;
  String?  _filePath;
  Timer?   _flushTimer;

  // Buffer up to 64 lines before an I/O flush to keep disk writes low.
  final List<String> _buffer = [];
  static const _bufferLimit = 64;

  // ── Init ──────────────────────────────────────────────────────────────────

  /// Call once at app start, after DeviceStorage is ready.
  ///
  /// [deviceName] should be the human-readable name set by the tester
  /// ('A', 'B', 'C', or the actual device display name).
  Future<void> init({required String deviceName, required String deviceId}) async {
    try {
      final dir = await _logDir();
      final now = DateTime.now();
      final datePart = _ymd(now);
      final timePart = _hms(now);

      // Sanitise name for filename (no spaces / special chars)
      final safeName = deviceName.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final fileName = 'offlink_${safeName}_${datePart}_$timePart.log';
      _filePath = '${dir.path}/$fileName';

      final file = File(_filePath!);
      _sink = file.openWrite(mode: FileMode.append);

      // ── Session header ────────────────────────────────────────────────────
      _writeLine('');
      _writeLine('═══════════════════════════════════════════════════════════');
      _writeLine('  OffLink Relay Test Log');
      _writeLine('  Device   : $deviceName');
      _writeLine('  UUID     : $deviceId');
      _writeLine('  Session  : ${now.toIso8601String()}');
      _writeLine('  File     : $_filePath');
      _writeLine('═══════════════════════════════════════════════════════════');
      _writeLine('');

      await _forceFlush(); // make header visible immediately

      // Auto-flush every 5 seconds so recent events survive a crash.
      _flushTimer = Timer.periodic(const Duration(seconds: 5), (_) => _forceFlush());
    } catch (e) {
      // FileLogger must never crash the app — swallow silently.
    }
  }

  // ── Public write API (called by Logger) ───────────────────────────────────

  void log(String level, String tag, String message) {
    _writeLine('[${_ts()}] [$level] [$tag] $message');
  }

  /// Write a blank separator line — useful for marking test phases.
  void separator(String label) {
    _writeLine('');
    _writeLine('─── $label ${DateTime.now().toIso8601String()} ───');
    _writeLine('');
    _forceFlush(); // flush immediately so the marker is always persisted
  }

  // ── Flush / close ─────────────────────────────────────────────────────────

  Future<void> flush() => _forceFlush();

  Future<void> close() async {
    _flushTimer?.cancel();
    await _forceFlush();
    await _sink?.close();
    _sink = null;
  }

  String? get filePath => _filePath;

  // ── Internals ─────────────────────────────────────────────────────────────

  void _writeLine(String line) {
    _buffer.add(line);
    if (_buffer.length >= _bufferLimit) _forceFlush();
  }

  Future<void> _forceFlush() async {
    if (_sink == null || _buffer.isEmpty) return;
    try {
      for (final line in _buffer) {
        _sink!.writeln(line);
      }
      _buffer.clear();
      await _sink!.flush();
    } catch (_) {}
  }

  static Future<Directory> _logDir() async {
    // Prefer external so files survive uninstall and are adb-pullable.
    Directory? ext;
    try {
      ext = await getExternalStorageDirectory();
    } catch (_) {}
    final base = ext ?? await getApplicationDocumentsDirectory();
    final logDir = Directory('${base.path}/logs');
    if (!logDir.existsSync()) logDir.createSync(recursive: true);
    return logDir;
  }

  static String _ts() {
    final t = DateTime.now();
    return '${_pad(t.hour)}:${_pad(t.minute)}:${_pad(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
  }

  static String _ymd(DateTime t) =>
      '${t.year}-${_pad(t.month)}-${_pad(t.day)}';

  static String _hms(DateTime t) =>
      '${_pad(t.hour)}-${_pad(t.minute)}-${_pad(t.second)}';

  static String _pad(int v) => v.toString().padLeft(2, '0');
}
