import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'logger.dart';

class PermissionsHelper {
  static const MethodChannel _permissionsChannel =
      MethodChannel('com.offlink.permissions');

  /// Check if location services are enabled (CRITICAL for Android 13+ BLE scanning)
  static Future<bool> isLocationEnabled() async {
    if (!Platform.isAndroid) return true; // Not applicable on other platforms
    
    try {
      final result = await _permissionsChannel.invokeMethod<bool>('isLocationEnabled');
      return result ?? false;
    } catch (e) {
      Logger.error('Error checking location services', e);
      return false;
    }
  }

  /// Check if all required Bluetooth permissions are granted (Android 13+)
  static Future<bool> checkBluetoothPermissions() async {
    if (!Platform.isAndroid) return true;
    
    try {
      final result = await _permissionsChannel.invokeMethod<bool>('checkBluetoothPermissions');
      return result ?? false;
    } catch (e) {
      Logger.error('Error checking Bluetooth permissions', e);
      return false;
    }
  }

  /// Check if Nearby Devices permission is supported
  /// Android 11: Uses Location permission
  /// Android 12: Uses Bluetooth permissions
  /// Android 13+: Uses NEARBY_WIFI_DEVICES permission
  static Future<bool> isNearbyDevicesPermissionSupported() async {
    if (!Platform.isAndroid) return false;
    // All Android versions support nearby devices through some permission
    return true;
  }
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

  /// Check if Nearby Devices permission is granted
  /// Android 11 (API 30 and below): Uses Location permission
  /// Android 12 (API 31-32): Uses Bluetooth permissions
  /// Android 13+ (API 33+): Uses NEARBY_WIFI_DEVICES permission
  static Future<bool> checkNearbyDevicesPermission() async {
    if (!Platform.isAndroid) return false;

    final sdkInt = await _getAndroidSdkInt();

    // Android 11 and below: use Location
    if (sdkInt <= 30) {
      Logger.debug('Android 11: Checking Location permission for nearby devices');
      return await checkLocationPermission();
    }

    // Android 12: use Bluetooth permissions
    if (sdkInt >= 31 && sdkInt <= 32) {
      Logger.debug('Android 12: Checking Bluetooth permissions for nearby devices');
      try {
        final scanGranted = await Permission.bluetoothScan.isGranted;
        final connectGranted = await Permission.bluetoothConnect.isGranted;
        final advertiseGranted = await _isBluetoothAdvertiseGranted();

        if (scanGranted && connectGranted && advertiseGranted) {
          Logger.debug(
              'Nearby Devices permission granted (via Bluetooth permissions on Android 12)');
          return true;
        }
        Logger.debug(
            'Nearby Devices permission not granted (Bluetooth permissions partial: SCAN=$scanGranted, CONNECT=$connectGranted, ADVERTISE=$advertiseGranted)');
        return false;
      } catch (e) {
        Logger.error(
            'Error checking Bluetooth permissions for nearby devices on Android 12: ${e.toString()}',
            e);
        return false;
      }
    }

    // Android 13+: use NEARBY_WIFI_DEVICES
    if (sdkInt >= 33) {
      Logger.debug('Android 13+: Checking NEARBY_WIFI_DEVICES permission');
      // Native check first
      try {
        final result = await _permissionsChannel
            .invokeMethod<bool>('checkNearbyDevicesPermission');
        if (result == true) {
          Logger.debug(
              'Nearby Devices permission granted (checked via native method on Android 13+)');
          return true;
        }
        Logger.debug(
            'Nearby Devices permission not granted (checked via native method)');
      } catch (e) {
        Logger.debug('Native permission check failed: ${e.toString()}');
      }

      // Fallback to permission_handler
      try {
        final status = await Permission.nearbyWifiDevices.status;
        Logger.debug(
            'Nearby Devices permission status via permission_handler: ${status.toString()}');
        if (status.isGranted) return true;

        if (status.isDenied) {
          await Future.delayed(const Duration(milliseconds: 300));
          final retryStatus = await Permission.nearbyWifiDevices.status;
          Logger.debug(
              'Nearby Devices permission retry status: ${retryStatus.toString()}');
          return retryStatus.isGranted;
        }
        return false;
      } catch (e) {
        Logger.error(
            'Error checking Nearby Devices permission on Android 13+: ${e.toString()}',
            e);
        return false;
      }
    }

    Logger.warning(
        'Unknown Android version for nearby devices permission check: SDK $sdkInt');
    return false;
  }

  /// Request Nearby Devices permission
  /// Android 11 (API 30 and below): Requests Location permission
  /// Android 12 (API 31-32): Requests Bluetooth permissions
  /// Android 13+ (API 33+): Requests NEARBY_WIFI_DEVICES permission
  static Future<bool> requestNearbyDevicesPermission() async {
    if (!Platform.isAndroid) return false;

    final sdkInt = await _getAndroidSdkInt();

    // Already granted?
    if (await checkNearbyDevicesPermission()) {
      Logger.debug('Nearby Devices permission already granted');
      return true;
    }

    if (sdkInt <= 30) {
      Logger.debug('Android 11: Requesting Location permission for nearby devices');
      return await requestLocationPermission();
    }

    if (sdkInt >= 31 && sdkInt <= 32) {
      Logger.debug('Android 12: Requesting Bluetooth permissions for nearby devices');
      try {
        final scanStatus = await Permission.bluetoothScan.request();
        final connectStatus = await Permission.bluetoothConnect.request();
        final advertiseStatus = await Permission.bluetoothAdvertise.request();

        Logger.info(
            'Bluetooth permissions request for nearby devices: SCAN=${scanStatus.toString()}, CONNECT=${connectStatus.toString()}, ADVERTISE=${advertiseStatus.toString()}');

        if (scanStatus.isGranted &&
            connectStatus.isGranted &&
            advertiseStatus.isGranted) {
          Logger.info(
              'Nearby Devices permission granted (via Bluetooth permissions on Android 12)');
          return true;
        }

        Logger.warning(
            'Nearby Devices permission not granted (partial Bluetooth permissions on Android 12)');
        return false;
      } catch (e) {
        Logger.error(
            'Error requesting Bluetooth permissions for nearby devices on Android 12: ${e.toString()}',
            e);
        return false;
      }
    }

    if (sdkInt >= 33) {
      Logger.debug('Android 13+: Requesting NEARBY_WIFI_DEVICES permission');
      try {
        final status = await Permission.nearbyWifiDevices.request();
        Logger.debug('Nearby Devices permission request result: ${status.toString()}');

        if (status.isDenied || status.isPermanentlyDenied) {
          await Future.delayed(const Duration(milliseconds: 500));
          final nativeCheck = await checkNearbyDevicesPermission();
          if (nativeCheck) {
            Logger.debug(
                'Nearby Devices permission granted (detected via native check after request)');
            return true;
          }
        }
        return status.isGranted;
      } catch (e) {
        Logger.error(
            'Error requesting Nearby Devices permission on Android 13+: ${e.toString()}',
            e);
        await Future.delayed(const Duration(milliseconds: 300));
        return await checkNearbyDevicesPermission();
      }
    }

    Logger.warning(
        'Unknown Android version for nearby devices permission request: SDK $sdkInt');
    return false;
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

  static Future<int> _getAndroidSdkInt() async {
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return androidInfo.version.sdkInt;
    } catch (e) {
      Logger.error('Error fetching Android SDK version', e);
      return 0;
    }
  }
}

