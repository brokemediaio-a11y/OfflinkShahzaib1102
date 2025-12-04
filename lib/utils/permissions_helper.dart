import 'package:permission_handler/permission_handler.dart';
import 'logger.dart';

class PermissionsHelper {
  // Check if Bluetooth permission is granted
  static Future<bool> checkBluetoothPermission() async {
    try {
      // For Android 12+ (API 31+), we need BLUETOOTH_SCAN and BLUETOOTH_CONNECT
      // For older versions, use the legacy BLUETOOTH permission
      if (await Permission.bluetoothScan.isGranted &&
          await Permission.bluetoothConnect.isGranted &&
          await _isBluetoothAdvertiseGranted()) {
        return true;
      }
      // Fallback for older Android versions
      try {
        if (await Permission.bluetooth.isGranted) {
          return true;
        }
      } catch (_) {
        // Permission.bluetooth might not be available on newer versions
      }
      return false;
    } catch (e) {
      Logger.error('Error checking Bluetooth permission', e);
      return false;
    }
  }

  // Request Bluetooth permission
  static Future<bool> requestBluetoothPermission() async {
    try {
      // For Android 12+ (API 31+), we need BLUETOOTH_SCAN and BLUETOOTH_CONNECT
      // The permission_handler package should handle this automatically
      
      // Try requesting the new Android 12+ permissions first
      try {
        // Request BLUETOOTH_SCAN permission
        var scanStatus = await Permission.bluetoothScan.request();
        Logger.info('BLUETOOTH_SCAN status: ${scanStatus.toString()}');
        
        // Request BLUETOOTH_CONNECT permission
        var connectStatus = await Permission.bluetoothConnect.request();
        Logger.info('BLUETOOTH_CONNECT status: ${connectStatus.toString()}');

        var advertiseStatus = await Permission.bluetoothAdvertise.request();
        Logger.info('BLUETOOTH_ADVERTISE status: ${advertiseStatus.toString()}');
        
        // Both are required for Android 12+
        if (scanStatus.isGranted && connectStatus.isGranted && advertiseStatus.isGranted) {
          Logger.info('Bluetooth permissions granted (Android 12+)');
          return true;
        }
        
        // If at least one is granted, log it
        if (scanStatus.isGranted || connectStatus.isGranted || advertiseStatus.isGranted) {
          Logger.warning(
            'Partial Bluetooth permissions: SCAN=${scanStatus.isGranted}, CONNECT=${connectStatus.isGranted}, ADVERTISE=${advertiseStatus.isGranted}',
          );
        }
      } catch (e) {
        Logger.debug('New Bluetooth permissions not available, trying legacy: ${e.toString()}');
      }
      
      // Fallback: Try legacy permission for older Android versions
      try {
        var bluetoothStatus = await Permission.bluetooth.request();
        Logger.info('Legacy BLUETOOTH status: ${bluetoothStatus.toString()}');
        if (bluetoothStatus.isGranted) {
          Logger.info('Bluetooth permission granted (legacy)');
          return true;
        }
      } catch (e) {
        Logger.debug('Legacy Bluetooth permission not available: ${e.toString()}');
      }
      
      Logger.warning('Bluetooth permissions not granted');
      return false;
    } catch (e) {
      Logger.error('Error requesting Bluetooth permission', e);
      return false;
    }
  }

  // Check if Location permission is granted
  static Future<bool> checkLocationPermission() async {
    try {
      final status = await Permission.location.status;
      return status.isGranted;
    } catch (e) {
      Logger.error('Error checking Location permission', e);
      return false;
    }
  }

  // Request Location permission
  static Future<bool> requestLocationPermission() async {
    try {
      final status = await Permission.location.request();
      return status.isGranted;
    } catch (e) {
      Logger.error('Error requesting Location permission', e);
      return false;
    }
  }

  // Check if Nearby Devices permission is granted (Android 12+)
  static Future<bool> checkNearbyDevicesPermission() async {
    try {
      final status = await Permission.nearbyWifiDevices.status;
      return status.isGranted;
    } catch (e) {
      // Permission might not be available on older Android versions
      Logger.debug('Nearby Devices permission not available');
      return true; // Assume granted for older versions
    }
  }

  // Request Nearby Devices permission
  static Future<bool> requestNearbyDevicesPermission() async {
    try {
      final status = await Permission.nearbyWifiDevices.request();
      return status.isGranted;
    } catch (e) {
      Logger.debug('Nearby Devices permission not available');
      return true; // Assume granted for older versions
    }
  }

  // Check all required permissions
  static Future<Map<String, bool>> checkAllPermissions() async {
    return {
      'bluetooth': await checkBluetoothPermission(),
      'location': await checkLocationPermission(),
      'nearbyDevices': await checkNearbyDevicesPermission(),
    };
  }

  // Request all required permissions
  static Future<Map<String, bool>> requestAllPermissions() async {
    return {
      'bluetooth': await requestBluetoothPermission(),
      'location': await requestLocationPermission(),
      'nearbyDevices': await requestNearbyDevicesPermission(),
    };
  }

  // Check if all permissions are granted
  static Future<bool> areAllPermissionsGranted() async {
    final permissions = await checkAllPermissions();
    return permissions.values.every((granted) => granted);
  }

  static Future<bool> _isBluetoothAdvertiseGranted() async {
    try {
      final status = await Permission.bluetoothAdvertise.status;
      return status.isGranted;
    } catch (_) {
      return true;
    }
  }
}

