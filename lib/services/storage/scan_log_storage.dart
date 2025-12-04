import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/logger.dart';

class ScanLogStorage {
  ScanLogStorage._internal();

  static final ScanLogStorage instance = ScanLogStorage._internal();

  final DateFormat _dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');
  File? _logFile;
  Future<void>? _initializationFuture;

  /// Ensures the log file exists and is cached.
  Future<void> _ensureInitialized() {
    if (_logFile != null) {
      return Future.value();
    }

    // Prevent concurrent initialization from creating multiple files.
    _initializationFuture ??= () async {
      try {
        final directory = await getApplicationDocumentsDirectory();
        final path = '${directory.path}/offlink_scanning_logs.txt';
        final file = File(path);

        if (!await file.exists()) {
          await file.create(recursive: true);
          await file.writeAsString(
            'Offlink scanning logs\n'
            '=====================\n',
            mode: FileMode.write,
          );
        }

        _logFile = file;
      } catch (e, stackTrace) {
        Logger.error('Failed to initialize scan log storage', e, stackTrace);
        rethrow;
      }
    }();

    return _initializationFuture!;
  }

  Future<void> logEvent(
    String message, {
    Map<String, Object?> metadata = const {},
  }) async {
    try {
      await _ensureInitialized();
      final timestamp = _dateFormat.format(DateTime.now());
      final buffer = StringBuffer()..write('[$timestamp] $message');

      if (metadata.isNotEmpty) {
        final formattedMeta = metadata.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join(' ');
        buffer.write(' | $formattedMeta');
      }

      buffer.write('\n');

      await _logFile!.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: false,
      );
    } catch (e, stackTrace) {
      Logger.error('Failed to write scan log entry', e, stackTrace);
    }
  }

  Future<String> readLogs() async {
    await _ensureInitialized();
    return _logFile!.readAsString();
  }

  Future<void> clearLogs() async {
    await _ensureInitialized();
    await _logFile!.writeAsString(
      'Offlink scanning logs\n'
      '=====================\n',
      mode: FileMode.write,
    );
  }

  String? get logFilePath => _logFile?.path;
}


