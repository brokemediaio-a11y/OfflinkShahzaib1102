import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../utils/logger.dart';

class DeviceStorage {
  static const String _deviceIdKey = 'device_id';
  static const String _displayNameKey = 'display_name';
  static const String _registrationCompleteKey = 'registration_complete';
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

  /// Get the user's display name, or return null if not set
  static String? getDisplayName() {
    try {
      return _deviceBox?.get(_displayNameKey) as String?;
    } catch (e) {
      Logger.error('Error getting display name', e);
      return null;
    }
  }

  /// Set the user's display name
  static Future<void> setDisplayName(String name) async {
    try {
      await _deviceBox?.put(_displayNameKey, name);
      Logger.info('Display name set to: $name');
    } catch (e) {
      Logger.error('Error setting display name', e);
    }
  }

  /// Check if user registration is complete
  static bool isRegistrationComplete() {
    try {
      return _deviceBox?.get(_registrationCompleteKey, defaultValue: false) as bool;
    } catch (e) {
      Logger.error('Error checking registration status', e);
      return false;
    }
  }

  /// Set registration complete status
  static Future<void> setRegistrationComplete(bool complete) async {
    try {
      await _deviceBox?.put(_registrationCompleteKey, complete);
      Logger.info('Registration complete status set to: $complete');
    } catch (e) {
      Logger.error('Error setting registration status', e);
    }
  }

  /// Clear registration (for testing/reset purposes)
  static Future<void> clearRegistration() async {
    try {
      await _deviceBox?.delete(_registrationCompleteKey);
      await _deviceBox?.delete(_displayNameKey);
      Logger.info('Registration data cleared');
    } catch (e) {
      Logger.error('Error clearing registration', e);
    }
  }

  /// Get display name for a device UUID (for storing other devices' names)
  static String? getDeviceDisplayName(String deviceId) {
    try {
      return _deviceBox?.get('device_name_$deviceId') as String?;
    } catch (e) {
      return null;
    }
  }

  /// Set display name for a device UUID (for storing other devices' names)
  static Future<void> setDeviceDisplayName(String deviceId, String name) async {
    try {
      await _deviceBox?.put('device_name_$deviceId', name);
      Logger.info('Device display name set: $deviceId -> $name');
    } catch (e) {
      Logger.error('Error setting device display name', e);
    }
  }

  /// UUID-MAC Mapping: Store MAC address for a UUID
  static Future<void> setMacForUuid(String uuid, String macAddress) async {
    try {
      if (_deviceBox != null) {
        await _deviceBox!.put('uuid_mac_$uuid', macAddress);
        Logger.debug('Stored MAC mapping: $uuid -> $macAddress');
      }
    } catch (e) {
      Logger.error('Error storing UUID-MAC mapping', e);
    }
  }

  /// UUID-MAC Mapping: Get MAC address for a UUID
  static String? getMacForUuid(String uuid) {
    try {
      return _deviceBox?.get('uuid_mac_$uuid') as String?;
    } catch (e) {
      Logger.error('Error getting MAC for UUID', e);
      return null;
    }
  }

  /// UUID-MAC Mapping: Get UUID for a MAC address
  static String? getUuidForMac(String macAddress) {
    try {
      if (_deviceBox == null) return null;
      
      // Need to iterate through all keys to find matching MAC
      // This is not ideal but Hive doesn't support reverse lookups efficiently
      final keys = _deviceBox!.keys.where((key) => key.toString().startsWith('uuid_mac_'));
      for (final key in keys) {
        final storedMac = _deviceBox!.get(key) as String?;
        if (storedMac == macAddress) {
          // Extract UUID from key (format: 'uuid_mac_<uuid>')
          final uuid = key.toString().replaceFirst('uuid_mac_', '');
          return uuid;
        }
      }
      return null;
    } catch (e) {
      Logger.error('Error getting UUID for MAC', e);
      return null;
    }
  }

  /// UUID-MAC Mapping: Remove mapping for a UUID
  static Future<void> removeMacMapping(String uuid) async {
    try {
      await _deviceBox?.delete('uuid_mac_$uuid');
      Logger.debug('Removed MAC mapping for UUID: $uuid');
    } catch (e) {
      Logger.error('Error removing MAC mapping', e);
    }
  }
}

