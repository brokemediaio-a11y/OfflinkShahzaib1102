import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import '../../models/device_model.dart';
import '../../core/constants.dart';
import '../../utils/logger.dart';
import '../storage/scan_log_storage.dart';
import '../storage/device_storage.dart';
import '../storage/message_storage.dart';

class BluetoothService {
  static final BluetoothService _instance = BluetoothService._internal();
  factory BluetoothService() => _instance;
  BluetoothService._internal();

  StreamSubscription<List<fbp.ScanResult>>? _scanSubscription;
  fbp.BluetoothDevice? _connectedDevice;
  fbp.BluetoothCharacteristic? _characteristic;
  StreamSubscription<List<int>>? _messageSubscription;
  Timer? _scanDiagnosticsTimer;

  final _discoveredDevices = <String, DeviceModel>{};
  final _deviceController = StreamController<List<DeviceModel>>.broadcast();
  final _messageController = StreamController<String>.broadcast();
  final ScanLogStorage _scanLogStorage = ScanLogStorage.instance;
  
  int _totalScanResultsReceived = 0;

  Stream<List<DeviceModel>> get discoveredDevices => _deviceController.stream;
  Stream<String> get incomingMessages => _messageController.stream;

  // Initialize Bluetooth
  Future<bool> initialize() async {
    try {
      // Check if Bluetooth is available
      final isAvailable = await fbp.FlutterBluePlus.isSupported;
      if (!isAvailable) {
        Logger.warning('Bluetooth is not available');
        return false;
      }

      // Check if Bluetooth is on
      final adapterState = await fbp.FlutterBluePlus.adapterState.first;
      if (adapterState != fbp.BluetoothAdapterState.on) {
        Logger.warning('Bluetooth is not turned on');
        return false;
      }

      Logger.info('Bluetooth service initialized');
      return true;
    } catch (e) {
      Logger.error('Error initializing Bluetooth service', e);
      return false;
    }
  }

  // Start scanning for devices
// In bluetooth_service.dart - Replace the startScan method

  // Maximum retry attempts for scan registration failures
  static const int _maxScanRetries = 3;
  static const Duration _scanRetryDelay = Duration(milliseconds: 1500);

  // Start scanning for devices with retry logic
  Future<void> startScan({int retryCount = 0}) async {
    try {
      // Don't call initialize() here - it's already done in ConnectionManager
      // Just verify Bluetooth is on
      final adapterState = await fbp.FlutterBluePlus.adapterState.first;
      if (adapterState != fbp.BluetoothAdapterState.on) {
        Logger.error('Bluetooth adapter is not ON, cannot scan');
        await _scanLogStorage.logEvent(
          'BLE scan failed: Bluetooth not ON',
          metadata: {'adapterState': adapterState.toString()},
        );
        throw Exception('Bluetooth adapter is not ON');
      }

      _discoveredDevices.clear();
      await _scanLogStorage.logEvent(
        'BLE scan requested',
        metadata: {
          'connected': isConnected(),
          'adapterState': adapterState.toString(),
          'retryCount': retryCount,
        },
      );
      
      final targetServiceUuid = AppConstants.bleServiceUuid.toUpperCase();
      
      Logger.info('Starting BLE scan (attempt ${retryCount + 1}/$_maxScanRetries)');
      Logger.info('Target service UUID: $targetServiceUuid');
      
      // Reset scan diagnostics
      _totalScanResultsReceived = 0;
      
      // Set up scan result listener BEFORE starting scan
      _scanSubscription?.cancel();
      _scanSubscription = fbp.FlutterBluePlus.scanResults.listen((results) {
        _processScanResults(results, targetServiceUuid);
      }, onError: (error) {
        Logger.error('Error during BLE scan', error);
        unawaited(_scanLogStorage.logEvent(
          'BLE scan error',
          metadata: {'error': error.toString()},
        ));
      });

      // Start scan and wait for it to actually start
      await fbp.FlutterBluePlus.startScan(
        timeout: AppConstants.bleScanTimeout,
        androidScanMode: fbp.AndroidScanMode.lowLatency,
      );
      
      // Verify scan actually started by checking isScanning
      await Future.delayed(const Duration(milliseconds: 100));
      final isActuallyScanning = fbp.FlutterBluePlus.isScanningNow;
      
      if (!isActuallyScanning) {
        throw Exception('Scan did not start - scanner may have failed to register');
      }
      
      Logger.info('BLE scan started successfully');
      await _scanLogStorage.logEvent('BLE scan started', metadata: {'retryCount': retryCount});
      
      // Set up diagnostics timer
      _scanDiagnosticsTimer?.cancel();
      _scanDiagnosticsTimer = Timer(const Duration(seconds: 5), () {
        if (_totalScanResultsReceived == 0) {
          Logger.warning('No scan results received after 5 seconds');
          unawaited(_scanLogStorage.logEvent(
            'Scan diagnostics: No results after 5s',
            metadata: {
              'totalResults': _totalScanResultsReceived,
              'discoveredDevices': _discoveredDevices.length,
            },
          ));
        }
      });
      
    } on fbp.FlutterBluePlusException catch (e) {
      // Handle specific scan failures
      if (e.code == 2 || e.description?.contains('APPLICATION_REGISTRATION_FAILED') == true) {
        Logger.warning('Scan registration failed (attempt ${retryCount + 1})');
        await _scanLogStorage.logEvent(
          'BLE scan registration failed',
          metadata: {'retryCount': retryCount, 'error': e.toString()},
        );
        
        if (retryCount < _maxScanRetries - 1) {
          Logger.info('Retrying scan in ${_scanRetryDelay.inMilliseconds}ms...');
          await Future.delayed(_scanRetryDelay);
          return startScan(retryCount: retryCount + 1);
        }
      }
      
      Logger.error('Error starting BLE scan', e);
      unawaited(_scanLogStorage.logEvent(
        'BLE scan start failure',
        metadata: {'error': e.toString(), 'retryCount': retryCount},
      ));
      rethrow;
    } catch (e) {
      // Generic error - check if it's a registration failure
      final errorStr = e.toString().toLowerCase();
      if (errorStr.contains('registration') || errorStr.contains('failed')) {
        Logger.warning('Possible scan registration failure (attempt ${retryCount + 1}): $e');
        
        if (retryCount < _maxScanRetries - 1) {
          Logger.info('Retrying scan in ${_scanRetryDelay.inMilliseconds}ms...');
          await Future.delayed(_scanRetryDelay);
          return startScan(retryCount: retryCount + 1);
        }
      }
      
      Logger.error('Error starting BLE scan', e);
      unawaited(_scanLogStorage.logEvent(
        'BLE scan start failure',
        metadata: {'error': e.toString(), 'retryCount': retryCount},
      ));
      rethrow;
    }
  }

  // Extracted method to process scan results
  Future<void> _processScanResults(List<fbp.ScanResult> results, String targetServiceUuid) async {
    _totalScanResultsReceived += results.length;
    Logger.debug('Scan results received: ${results.length} devices');
    
    for (var result in results) {
      final macAddress = result.device.remoteId.str; // MAC address for connection
      final deviceName = result.device.platformName.isNotEmpty
          ? result.device.platformName
          : 'Unknown Device';
      
      // Android 13+ often doesn't expose Service UUIDs in scan results
      // We should NOT rely on serviceUuids for device identification
      final serviceUuids = result.advertisementData.serviceUuids
          .map((u) => u.str.toUpperCase())
          .toList();
      
      // CRITICAL: Extract device UUID from manufacturer data (manufacturer ID 0xFFFF)
      // This is the ONLY reliable way to identify devices on Android 13+
      // Format: 16 bytes representing the UUID (big-endian, MSB first, then LSB)
      String? deviceUuid;
      try {
        final manufacturerData = result.advertisementData.manufacturerData;
        if (manufacturerData.containsKey(0xFFFF)) {
          final uuidBytes = manufacturerData[0xFFFF]!;
          if (uuidBytes.length >= 16) {
            // Extract 16-byte UUID
            final uuidBytesList = uuidBytes.sublist(0, 16);
            
            // Convert bytes to two 64-bit integers (MSB and LSB)
            // Match Kotlin implementation: bytes are in big-endian order
            // byte 0 (MSB[63:56]) shifted left by 56 bits, byte 7 (MSB[7:0]) shifted left by 0 bits
            int msb = 0;
            int lsb = 0;
            for (int i = 0; i < 8; i++) {
              msb = msb | ((uuidBytesList[i] & 0xFF) << (56 - (i * 8)));
            }
            for (int i = 0; i < 8; i++) {
              lsb = lsb | ((uuidBytesList[8 + i] & 0xFF) << (56 - (i * 8)));
            }
            
            // Convert to UUID string format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
            // UUID layout: MSB[63:32]=time_low, MSB[31:16]=time_mid, MSB[15:0]=time_hi_and_version
            // LSB[63:56]=clock_seq_hi_and_reserved, LSB[55:48]=clock_seq_low, LSB[47:0]=node
            final timeLow = (msb >> 32) & 0xFFFFFFFF;
            final timeMid = (msb >> 16) & 0xFFFF;
            final timeHiAndVersion = msb & 0xFFFF;
            final clockSeqHiAndReserved = (lsb >> 56) & 0xFF;
            final clockSeqLow = (lsb >> 48) & 0xFF;
            final node = lsb & 0xFFFFFFFFFFFF;
            
            // Format as UUID string (lowercase)
            deviceUuid = '${timeLow.toRadixString(16).padLeft(8, '0')}-'
                '${timeMid.toRadixString(16).padLeft(4, '0')}-'
                '${timeHiAndVersion.toRadixString(16).padLeft(4, '0')}-'
                '${clockSeqHiAndReserved.toRadixString(16).padLeft(2, '0')}'
                '${clockSeqLow.toRadixString(16).padLeft(2, '0')}-'
                '${node.toRadixString(16).padLeft(12, '0')}'.toLowerCase();
            
            Logger.debug('Extracted UUID from FBP manufacturer data: $deviceUuid');
          }
        }
      } catch (e) {
        Logger.debug('Could not extract UUID from advertisement: $e');
      }
      
      // CRITICAL: Only use UUID, never MAC as device ID
      // On Android 13+, Service UUIDs are often empty - we MUST use manufacturer data
      // If no UUID found in manufacturer data, skip this device (it's not an Offlink device)
      if (deviceUuid == null) {
        Logger.debug('Skipping device without UUID in manufacturer data: $deviceName ($macAddress)');
        Logger.debug('  Service UUIDs: ${serviceUuids.length} (may be empty on Android 13+)');
        try {
          final mfgData = result.advertisementData.manufacturerData;
          Logger.debug('  Manufacturer data keys: ${mfgData.keys.toList()}');
        } catch (e) {
          Logger.debug('  Could not read manufacturer data: $e');
        }
        continue; // Skip devices without UUID
      }
      
      // At this point, deviceUuid is guaranteed to be non-null
      final uuid = deviceUuid;
      
      // Store UUID-MAC mapping for future reference
      unawaited(DeviceStorage.setMacForUuid(uuid, macAddress));
      
      // Check if we have a stored name for this device first
      final storedName = DeviceStorage.getDeviceDisplayName(uuid);
      String displayName = storedName ?? deviceName;
      
      // Store the device name if we got a proper name (not "Unknown Device", not empty, not just UUID/MAC)
      if (deviceName.isNotEmpty && 
          deviceName != 'Unknown Device' && 
          deviceName != uuid && 
          deviceName != macAddress &&
          !uuid.contains(':') && // Only for UUID-based IDs
          storedName == null) {
        unawaited(DeviceStorage.setDeviceDisplayName(uuid, deviceName));
        displayName = deviceName; // Use the discovered name immediately
        Logger.debug('Storing discovered device name: $uuid -> $deviceName');
      }
      
      Logger.debug(
        'BLE scan result: id=$uuid (MAC: $macAddress) name=$displayName rssi=${result.rssi} '
        'serviceUuids=$serviceUuids',
      );

      final device = DeviceModel(
        id: uuid, // Always UUID, never MAC
        name: displayName, // Use stored name or discovered name
        address: macAddress, // Keep MAC for BLE connection (required by flutter_blue_plus)
        type: DeviceType.ble,
        rssi: result.rssi,
        lastSeen: DateTime.now(),
      );

      // Match by manufacturer data (UUID in 0xFFFF) or device name or service UUID
      // Since we removed device name and service UUID from advertisement to save space,
      // primary matching is now by manufacturer data containing UUID
      // deviceUuid is guaranteed to be non-null here (we continue if null above)
      // If we have a UUID, it's an Offlink device - add it to discovered devices
      _discoveredDevices[device.id] = device;
      _deviceController.add(_discoveredDevices.values.toList());
      Logger.info('Found Offlink device: $displayName (UUID: $uuid, MAC: $macAddress)');
    }
  }

  // Stop scanning
  Future<void> stopScan() async {
    try {
      _scanDiagnosticsTimer?.cancel();
      _scanDiagnosticsTimer = null;
      
      await fbp.FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      
      Logger.info('BLE scan stopped. Total results: $_totalScanResultsReceived, Discovered devices: ${_discoveredDevices.length}');
      await _scanLogStorage.logEvent(
        'BLE scan stopped',
        metadata: {
          'totalResults': _totalScanResultsReceived,
          'discoveredDevices': _discoveredDevices.length,
        },
      );
      
      _totalScanResultsReceived = 0;
    } catch (e) {
      Logger.error('Error stopping BLE scan', e);
      unawaited(_scanLogStorage.logEvent(
        'BLE scan stop failure',
        metadata: {'error': e.toString()},
      ));
    }
  }

  // Connect to a device
  Future<bool> connectToDevice(DeviceModel device) async {
    try {
      // Disconnect any existing connection first
      if (_connectedDevice != null) {
        Logger.info('Disconnecting existing connection before connecting to ${device.name}');
        try {
          await _connectedDevice!.disconnect();
          await Future.delayed(const Duration(milliseconds: 500)); // Wait for disconnect to complete
          _connectedDevice = null;
          _characteristic = null;
        } catch (e) {
          Logger.warning('Error disconnecting existing device: $e');
        }
      }
      
      // For BLE connections, we need MAC address
      // If address is null, use id (which should be MAC in legacy cases)
      final connectionAddress = device.address ?? device.id;
      if (connectionAddress.isEmpty) {
        Logger.error('Cannot connect: device has no MAC address');
        return false;
      }
      
      // Normalize MAC address format (remove any colons/spaces, ensure uppercase)
      String normalizedAddress = connectionAddress.toUpperCase().replaceAll(RegExp(r'[:\s-]'), '');
      // Re-add colons for flutter_blue_plus format (XX:XX:XX:XX:XX:XX)
      if (normalizedAddress.length == 12) {
        normalizedAddress = normalizedAddress.replaceAllMapped(
          RegExp(r'(.{2})'),
          (match) => '${match.group(1)}:',
        ).substring(0, 17); // Remove trailing colon
      }
      
      Logger.info('Connecting to device: ${device.name}');
      Logger.info('  Original address: $connectionAddress');
      Logger.info('  Normalized address: $normalizedAddress');
      Logger.info('  Device ID (UUID): ${device.id}');
      
      final bluetoothDevice = fbp.BluetoothDevice.fromId(normalizedAddress);

      // Connect to device with retry logic for bonded devices
      Logger.info('Attempting to connect to ${device.name} (UUID: ${device.id}, MAC: $normalizedAddress)');
      print('[OFFLINK] Attempting to connect to ${device.name} ($normalizedAddress)');
      
      int retryCount = 0;
      const maxRetries = 2;
      bool connected = false;
      
      while (retryCount <= maxRetries && !connected) {
        try {
          if (retryCount > 0) {
            Logger.info('Retrying connection (attempt ${retryCount + 1}/${maxRetries + 1})...');
            await Future.delayed(Duration(milliseconds: 1000 * retryCount)); // Exponential backoff
          }
          
          await bluetoothDevice.connect(
            timeout: AppConstants.connectionTimeout,
            autoConnect: false,
          );
          connected = true;
        } catch (e) {
          Logger.warning('Connection attempt ${retryCount + 1} failed: $e');
          if (retryCount < maxRetries) {
            retryCount++;
            // Disconnect if partially connected
            try {
              await bluetoothDevice.disconnect();
              await Future.delayed(const Duration(milliseconds: 500));
            } catch (_) {
              // Ignore disconnect errors
            }
          } else {
            Logger.error('All connection attempts failed');
            rethrow;
          }
        }
      }
      
      if (!connected) {
        Logger.error('Failed to connect after ${maxRetries + 1} attempts');
        return false;
      }

      Logger.info('Connection established to ${device.name}');
      print('[OFFLINK] Connection established to ${device.name}');
      _connectedDevice = bluetoothDevice;

      // Wait a moment for connection to stabilize (longer for bonded devices)
      await Future.delayed(const Duration(milliseconds: 500));

      // Check connection state before discovering services
      final connectionState = await bluetoothDevice.connectionState.first.timeout(
        const Duration(seconds: 2),
        onTimeout: () => fbp.BluetoothConnectionState.disconnected,
      );
      
      if (connectionState != fbp.BluetoothConnectionState.connected) {
        Logger.error('Device ${device.name} disconnected before service discovery');
        print('[OFFLINK] ERROR: Device disconnected before service discovery');
        return false;
      }

      // Check connection state again after the wait
      final finalConnectionState = await bluetoothDevice.connectionState.first.timeout(
        const Duration(seconds: 1),
        onTimeout: () => fbp.BluetoothConnectionState.disconnected,
      );
      
      if (finalConnectionState != fbp.BluetoothConnectionState.connected) {
        Logger.error('Device ${device.name} disconnected during wait period');
        print('[OFFLINK] ERROR: Device disconnected during wait period');
        return false;
      }

      // Discover services
      Logger.info('Discovering services on ${device.name}...');
      print('[OFFLINK] Discovering services on ${device.name}...');
      
      List<fbp.BluetoothService> services;
      try {
        services = await bluetoothDevice.discoverServices().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            Logger.error('Service discovery timed out for ${device.name}');
            print('[OFFLINK] ERROR: Service discovery timed out');
            throw TimeoutException('Service discovery timed out', const Duration(seconds: 15));
          },
        );
        
        Logger.info('Service discovery completed for ${device.name}');
        print('[OFFLINK] Service discovery completed: ${services.length} services found');
      } catch (e) {
        Logger.error('Error discovering services: $e');
        print('[OFFLINK] ERROR: Service discovery failed: $e');
        return false;
      }
      
      Logger.info('=== SERVICE DISCOVERY START ===');
      print('[OFFLINK] === SERVICE DISCOVERY START ===');
      Logger.info('Discovered ${services.length} services on ${device.name}');
      print('[OFFLINK] Discovered ${services.length} services on ${device.name}');
      Logger.info('Device address: ${device.address}');
      
      for (var service in services) {
        final serviceUuid = service.uuid.toString().toUpperCase();
        Logger.info('Service UUID: $serviceUuid');
        print('[OFFLINK] Service UUID: $serviceUuid');
        Logger.info('  Characteristics: ${service.characteristics.length}');
        for (var char in service.characteristics) {
          final charUuid = char.uuid.toString().toUpperCase();
          Logger.info('    Characteristic: $charUuid');
          print('[OFFLINK]   Characteristic: $charUuid');
        }
      }
      Logger.info('=== SERVICE DISCOVERY END ===');
      print('[OFFLINK] === SERVICE DISCOVERY END ===');
      
      // Find our service and characteristic
      final targetServiceUuid = AppConstants.bleServiceUuid.toUpperCase();
      final targetCharUuid = AppConstants.bleCharacteristicUuid.toUpperCase();
      
      Logger.info('Looking for service: $targetServiceUuid');
      Logger.info('Looking for characteristic: $targetCharUuid');
      
      for (var service in services) {
        final serviceUuid = service.uuid.toString().toUpperCase();
        Logger.debug('Checking service: $serviceUuid');
        
        if (serviceUuid == targetServiceUuid) {
          Logger.info('Found target service: $serviceUuid');
          
          for (var characteristic in service.characteristics) {
            final charUuid = characteristic.uuid.toString().toUpperCase();
            Logger.debug('Checking characteristic: $charUuid');
            
            if (charUuid == targetCharUuid) {
              Logger.info('Found target characteristic: $charUuid');
              _characteristic = characteristic;

              // Subscribe to notifications with error handling
              try {
                await characteristic.setNotifyValue(true);
                Logger.info('Notifications enabled for characteristic');
                
                // Listen for incoming messages
                _messageSubscription = characteristic.onValueReceived.listen(
                  (value) {
                    final message = String.fromCharCodes(value);
                    _messageController.add(message);
                    Logger.debug('Received message via BLE: $message');
                  },
                );
              } catch (e) {
                Logger.error('Failed to enable notifications: $e');
                // Still proceed - connection might work for sending messages
                // but receiving won't work
                unawaited(_scanLogStorage.logEvent(
                  'BLE notification enable failed',
                  metadata: {
                    'deviceId': device.id,
                    'error': e.toString(),
                  },
                ));
              }

              // Get the actual device name after connection
              final actualDeviceName = bluetoothDevice.platformName.isNotEmpty
                  ? bluetoothDevice.platformName
                  : device.name;
              
              Logger.info('Connected to device: $actualDeviceName');
              unawaited(_scanLogStorage.logEvent(
                'BLE device connected',
                metadata: {
                  'deviceId': device.id,
                  'name': actualDeviceName,
                  'address': device.address,
                },
              ));
              return true;
            }
          }
        }
      }

      Logger.error('Service or characteristic not found');
      Logger.error('Expected service: $targetServiceUuid');
      Logger.error('Expected characteristic: $targetCharUuid');
      Logger.error('Available services: ${services.map((s) => s.uuid.toString().toUpperCase()).join(", ")}');
      
      unawaited(_scanLogStorage.logEvent(
        'BLE connect failure - characteristic not found',
        metadata: {
          'deviceId': device.id,
          'name': device.name,
          'expectedService': targetServiceUuid,
          'expectedCharacteristic': targetCharUuid,
          'foundServices': services.map((s) => s.uuid.toString().toUpperCase()).toList(),
        },
      ));
      return false;
    } catch (e, stackTrace) {
      Logger.error('Error connecting to device: ${e.toString()}', e);
      Logger.error('Stack trace: $stackTrace');
      
      // Clean up on error
      try {
        if (_connectedDevice != null) {
          await _connectedDevice!.disconnect();
          _connectedDevice = null;
        }
      } catch (_) {
        // Ignore disconnect errors
      }
      
      unawaited(_scanLogStorage.logEvent(
        'BLE connect failure',
        metadata: {
          'deviceId': device.id,
          'name': device.name,
          'address': device.address,
          'error': e.toString(),
        },
      ));
      return false;
    }
  }

  // Disconnect from device
  Future<void> disconnect() async {
    try {
      await _messageSubscription?.cancel();
      _messageSubscription = null;
      
      if (_connectedDevice != null) {
        await _connectedDevice!.disconnect();
        _connectedDevice = null;
        _characteristic = null;
        Logger.info('Disconnected from device');
        unawaited(_scanLogStorage.logEvent('BLE device disconnected'));
      }
    } catch (e) {
      Logger.error('Error disconnecting', e);
      unawaited(_scanLogStorage.logEvent(
        'BLE disconnect failure',
        metadata: {'error': e.toString()},
      ));
    }
  }

  // Send message
  Future<bool> sendMessage(String message) async {
    try {
      if (_characteristic == null) {
        Logger.error('Not connected to any device');
        unawaited(_scanLogStorage.logEvent(
          'BLE message send failure',
          metadata: {'reason': 'not_connected'},
        ));
        return false;
      }

      final messageBytes = message.codeUnits;
      await _characteristic!.write(messageBytes, withoutResponse: false);
      
      Logger.debug('Message sent via BLE: $message');
      unawaited(_scanLogStorage.logEvent(
        'BLE message sent',
        metadata: {'length': message.length, 'preview': message},
      ));
      return true;
    } catch (e) {
      Logger.error('Error sending message', e);
      unawaited(_scanLogStorage.logEvent(
        'BLE message send failure',
        metadata: {'error': e.toString()},
      ));
      return false;
    }
  }

  // Check if connected
  bool isConnected() {
    return _connectedDevice != null && _characteristic != null;
  }

  // Get connected device
  DeviceModel? getConnectedDevice() {
    if (_connectedDevice == null) return null;
    
    // Get the actual device name from platform
    final platformName = _connectedDevice!.platformName.isNotEmpty
        ? _connectedDevice!.platformName
        : 'Unknown Device';
    
    final macAddress = _connectedDevice!.remoteId.str;
    
    // CRITICAL: Always try to find UUID first, never use MAC as ID
    String? deviceUuid;
    
    // Strategy 1: Check discovered devices by MAC
    try {
      final discoveredDevice = _discoveredDevices.values.firstWhere(
        (d) => d.address == macAddress,
      );
      deviceUuid = discoveredDevice.id;
      // Ensure it's a UUID, not MAC
      if (deviceUuid.contains(':')) {
        deviceUuid = null; // This is MAC, not UUID
      }
    } catch (e) {
      // Not in discovered devices
    }
    
    // Strategy 2: Check UUID-MAC mapping storage
    if (deviceUuid == null) {
      deviceUuid = DeviceStorage.getUuidForMac(macAddress);
    }
    
    // Strategy 3: Check messages for UUID associated with this MAC
    if (deviceUuid == null) {
      final allMessages = MessageStorage.getAllMessages();
      // Find most recent message where receiverId is this MAC (when we received)
      // or senderId matches a UUID and we have messages with this MAC
      for (final message in allMessages.reversed) {
        if (!message.isSent && message.receiverId == macAddress) {
          // We received from this MAC, senderId should be UUID
          if (!message.senderId.contains(':')) {
            deviceUuid = message.senderId;
            // Store mapping for future use
            DeviceStorage.setMacForUuid(deviceUuid, macAddress);
            break;
          }
        }
      }
    }
    
    // CRITICAL: If still no UUID found, return null instead of using MAC
    // This prevents the UUID-to-MAC conversion issue
    if (deviceUuid == null) {
      Logger.error('⚠️ Cannot find UUID for connected device with MAC: $macAddress');
      Logger.error('⚠️ Returning null to prevent MAC-based device identification');
      return null;
    }
    
    final storedName = DeviceStorage.getDeviceDisplayName(deviceUuid);
    final finalDeviceName = storedName ?? 
                           (platformName != 'Unknown Device' && platformName.isNotEmpty && platformName != deviceUuid ? platformName : 'Unknown Device');
    
    // Store the device name if we got a proper name from platform and it's different
    if (platformName.isNotEmpty && 
        platformName != 'Unknown Device' && 
        platformName != deviceUuid &&
        platformName != macAddress &&
        !deviceUuid.contains(':') && // Only for UUID-based IDs
        storedName == null) {
      unawaited(DeviceStorage.setDeviceDisplayName(deviceUuid, platformName));
      Logger.info('Storing device name from platform after connection: $deviceUuid -> $platformName');
    }
    
    // ALWAYS return device with UUID as ID, MAC only in address field
    return DeviceModel(
      id: deviceUuid, // UUID, never MAC
      name: finalDeviceName,
      address: macAddress, // MAC only for connection purposes
      type: DeviceType.ble,
      isConnected: true,
    );
  }

  // Dispose
  void dispose() {
    _scanDiagnosticsTimer?.cancel();
    _scanSubscription?.cancel();
    _messageSubscription?.cancel();
    _deviceController.close();
    _messageController.close();
    disconnect();
  }
}

