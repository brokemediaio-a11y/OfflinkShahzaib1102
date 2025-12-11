import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../utils/logger.dart';

class DeviceStorage {
  static const String _deviceIdKey = 'device_id';
  static const String _deviceBoxName = 'device_preferences';
  static Box? _deviceBox;

  static Future<void> init() async {
    try {
      _deviceBox = await Hive.openBox(_deviceBoxName);
      Logger.info('Device storage initialized');
    } catch (e) {
      Logger.error('Error initializing device storage', e);
      rethrow;
    }
  }

  /// Get the persistent device ID, or generate and store a new one if it doesn't exist
  static String getDeviceId() {
    try {
      if (_deviceBox == null) {
        Logger.warning('Device storage not initialized, generating new UUID');
        return _generateAndStoreDeviceId();
      }

      final storedId = _deviceBox!.get(_deviceIdKey) as String?;
      
      if (storedId != null && storedId.isNotEmpty) {
        Logger.info('Retrieved persistent device ID: $storedId');
        return storedId;
      }

      // No stored ID, generate and store a new one
      return _generateAndStoreDeviceId();
    } catch (e) {
      Logger.error('Error getting device ID', e);
      // Fallback: generate a new one (but don't store it if storage failed)
      return const Uuid().v4();
    }
  }

  static String _generateAndStoreDeviceId() {
    try {
      final newId = const Uuid().v4();
      if (_deviceBox != null) {
        _deviceBox!.put(_deviceIdKey, newId);
        Logger.info('Generated and stored new device ID: $newId');
      } else {
        Logger.warning('Device storage not initialized, cannot store new UUID');
      }
      return newId;
    } catch (e) {
      Logger.error('Error generating device ID', e);
      return const Uuid().v4();
    }
  }

  /// Clear the stored device ID (for testing/reset purposes)
  static Future<void> clearDeviceId() async {
    try {
      await _deviceBox?.delete(_deviceIdKey);
      Logger.info('Device ID cleared');
    } catch (e) {
      Logger.error('Error clearing device ID', e);
    }
  }
}

