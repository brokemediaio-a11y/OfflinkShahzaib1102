import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../models/message_model.dart';
import '../../utils/logger.dart';
import '../storage/scan_log_storage.dart';
import '../storage/device_storage.dart';
import '../storage/message_storage.dart';
import 'ble_peripheral_service.dart';
import 'bluetooth_service.dart';
import 'wifi_direct_service.dart';

enum ConnectionType {
  ble,
  wifiDirect,
  none,
}

class ConnectionManager {
  static final ConnectionManager _instance = ConnectionManager._internal();
  factory ConnectionManager() => _instance;
  ConnectionManager._internal() {
    _bleDiscoverySubscription =
        _bluetoothService.discoveredDevices.listen((devices) {
      _bleDevices = devices;
      _emitDiscoveredDevices();
    });

    _wifiDiscoverySubscription =
        _wifiDirectService.discoveredDevices.listen((devices) {
      _wifiDevices = devices;
      _emitDiscoveredDevices();
    });
    
    // Listen for native scan results
    _nativeScanSubscription = _blePeripheralService.scanResults.listen((result) {
      _handleNativeScanResult(result);
    });
    
    // NOTE: Connection state listener will be set up in _ensurePeripheralStarted()
    // after BlePeripheralService is initialized, because the EventChannel stream
    // needs to be active first. Setting it up here (before init) won't work.
  }

  final BluetoothService _bluetoothService = BluetoothService();
  final WifiDirectService _wifiDirectService = WifiDirectService();
  final BlePeripheralService _blePeripheralService = BlePeripheralService();
  final ScanLogStorage _scanLogStorage = ScanLogStorage.instance;

  ConnectionType _currentConnectionType = ConnectionType.none;
  DeviceModel? _connectedDevice;

  final _connectionController = StreamController<ConnectionState>.broadcast();
  final _messageController = StreamController<String>.broadcast();
  final _deviceStreamController = StreamController<List<DeviceModel>>.broadcast();

  List<DeviceModel> _bleDevices = const <DeviceModel>[];
  List<DeviceModel> _wifiDevices = const <DeviceModel>[];
  final Map<String, DeviceModel> _nativeScanDevices = {};

  bool _peripheralInitialized = false;
  bool _peripheralListening = false;
  bool _isAdvertising = false;
  bool _isInitialized = false;
  bool _useNativeScanner = false;  // Flag to use native scanner
  bool _nativeScannerFailed = false;
  bool _isPeripheralConnection = false;  // Track if we're connected as peripheral

  StreamSubscription<List<DeviceModel>>? _bleDiscoverySubscription;
  StreamSubscription<List<DeviceModel>>? _wifiDiscoverySubscription;
  StreamSubscription<Map<String, dynamic>>? _nativeScanSubscription;
  StreamSubscription<Map<String, dynamic>>? _peripheralConnectionStateSubscription;

  Stream<ConnectionState> get connectionState => _connectionController.stream;
  Stream<String> get incomingMessages => _messageController.stream;

  ConnectionType get currentConnectionType => _currentConnectionType;
  DeviceModel? get connectedDevice => _connectedDevice;

  Future<bool> initialize() async {
    if (_isInitialized) {
      await _ensurePeripheralStarted();
      return true;
    }
    try {
      final bleInitialized = await _bluetoothService.initialize();
      final wifiInitialized = await _wifiDirectService.initialize();

      _bluetoothService.incomingMessages.listen((message) {
        Logger.info('Message received via BluetoothService (central): $message');
        _messageController.add(message);
      });

      _wifiDirectService.incomingMessages.listen((message) {
        _messageController.add(message);
      });

      // Listen for messages from peripheral (when we receive as GATT server)
      _blePeripheralService.incomingMessages.listen((message) {
        Logger.info('Message received via BlePeripheralService (peripheral): $message');
        _messageController.add(message);
      });

      final initialized = bleInitialized || wifiInitialized;
      Logger.info(
          'Connection manager initialized (BLE: $bleInitialized, Wi-Fi Direct: $wifiInitialized)');
      
      // Check if we should use native scanner (for TECNO devices)
      _useNativeScanner = await _shouldUseNativeScanner();
      Logger.info('Native scanner mode: $_useNativeScanner');

      if (initialized) {
        _isInitialized = true;
        if (bleInitialized) {
          unawaited(_ensurePeripheralStarted());
        }
      }

      return initialized;
    } catch (e) {
      Logger.error('Error initializing connection manager', e);
      return false;
    }
  }

  // Check if device should use native scanner (TECNO and similar devices)
  Future<bool> _shouldUseNativeScanner() async {
    if (!Platform.isAndroid) return false;
    
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final manufacturer = androidInfo.manufacturer.toLowerCase();
      final model = androidInfo.model.toLowerCase();
      final brand = androidInfo.brand.toLowerCase();
      
      Logger.info('Device: manufacturer=$manufacturer, model=$model, brand=$brand');
      
      // TECNO and Transsion Holdings devices (TECNO, Infinix, itel)
      final problematicDevices = [
        'tecno', 'infinix', 'itel', 'transsion',
        'cla', 'camon',  // TECNO model identifiers
      ];
      
      for (final pattern in problematicDevices) {
        if (manufacturer.contains(pattern) || 
            model.contains(pattern) || 
            brand.contains(pattern)) {
          Logger.info('Detected problematic device ($pattern) - will use native scanner');
          return true;
        }
      }
      
      return false;
    } catch (e) {
      Logger.warning('Error detecting device type: $e');
      return false;
    }
  }

  Future<void> startScan({bool useBle = true, bool useWifiDirect = false}) async {
    bool advertisingWasStopped = false;
    try {
      // CRITICAL: Don't scan if we have an active peripheral connection
      // Scanning will disconnect the central that's connected to us
      if (_isPeripheralConnection && _connectedDevice != null) {
        Logger.warning('⚠️ Cannot scan: Active peripheral connection to ${_connectedDevice!.name}');
        Logger.warning('⚠️ Scanning would disconnect the connected central. Use existing connection to send messages.');
        throw Exception('Cannot scan while peripheral connection is active. Device ${_connectedDevice!.name} is already connected.');
      }
      
      // Clear previous results
      _nativeScanDevices.clear();
      
      try {
        await _bluetoothService.stopScan();
        await _blePeripheralService.stopNativeScan();
      } catch (e) {
        Logger.debug('No existing scan to stop: $e');
      }
      
      await Future.delayed(const Duration(milliseconds: 500));
      
      final shouldStopAdvertising = await _shouldStopAdvertisingForScan();
      Logger.info('Should stop advertising for scan: $shouldStopAdvertising');
      
      if (shouldStopAdvertising) {
        Logger.info('Suspending peripheral role for scanning');
        try {
          await _blePeripheralService.suspendForScanning();
          Logger.info('Peripheral suspended successfully');
        } catch (e) {
          Logger.error('Error suspending peripheral: $e');
          rethrow;
        }
        _isAdvertising = false;
        advertisingWasStopped = true;
        
        // Get appropriate delay for device
        final delayMs = await _getScanDelayForDevice();
        Logger.info('Waiting ${delayMs}ms for BLE stack to settle...');
        await Future.delayed(Duration(milliseconds: delayMs));
      } else {
        await _ensurePeripheralStarted();
      }
      
      if (useBle) {
        // Try native scanner first for problematic devices
        if (_useNativeScanner && !_nativeScannerFailed) {
          Logger.info('Using native BLE scanner (TECNO mode)');
          final result = await _blePeripheralService.startNativeScan(
            timeoutMs: AppConstants.bleScanTimeout.inMilliseconds,
          );
          
          if (result['success'] == true) {
            Logger.info('Native scan started successfully');
            unawaited(_scanLogStorage.logEvent(
              'Native BLE scan started',
              metadata: {'retry': result['retry'] ?? 0},
            ));
            return;
          } else {
            Logger.warning('Native scan failed: ${result['error']}');
            _nativeScannerFailed = true;  // Fall back to flutter_blue_plus
          }
        }
        
        // Fall back to flutter_blue_plus
        Logger.info('Using flutter_blue_plus scanner');
        await _bluetoothService.startScan();
        Logger.info('BLE scan started successfully');
      }
      
      unawaited(_scanLogStorage.logEvent(
        'Device scan started',
        metadata: {
          'ble': useBle,
          'useNative': _useNativeScanner && !_nativeScannerFailed,
          'advertisingStopped': advertisingWasStopped
        },
      ));
    } catch (e) {
      Logger.error('Error starting device scan', e);
      unawaited(_scanLogStorage.logEvent(
        'Device scan start failure',
        metadata: {'error': e.toString(), 'advertisingWasStopped': advertisingWasStopped},
      ));
      if (advertisingWasStopped) {
        await _restartAdvertisingAfterScan();
      }
      rethrow;
    }
  }

  // Handle results from native scanner
  void _handleNativeScanResult(Map<String, dynamic> result) {
    // Check if it's an error
    if (result['error'] == true) {
      Logger.error('Native scan error: ${result['errorName']} (${result['errorCode']})');
      unawaited(_scanLogStorage.logEvent(
        'Native scan error',
        metadata: result,
      ));
      return;
    }
    
    // Process device result
    final deviceId = result['id'] as String?;
    final deviceName = result['name'] as String? ?? 'Unknown Device';
    final rssi = result['rssi'] as int? ?? -100;
    
    if (deviceId != null) {
      // Extract device UUID from scan result (preferred) or use MAC as fallback
      final deviceUuid = result['deviceUuid'] as String?;
      final macAddress = result['macAddress'] as String? ?? deviceId;
      final finalDeviceId = (deviceUuid != null && deviceUuid.isNotEmpty) ? deviceUuid : deviceId;
      
      // Check if we have a stored name for this device first
      final storedName = DeviceStorage.getDeviceDisplayName(finalDeviceId);
      String displayName = storedName ?? deviceName;
      
      // Store the device name if we got a proper name (not "Unknown Device", not empty, not just UUID/MAC)
      if (deviceUuid != null &&
          finalDeviceId == deviceUuid && // Only store for UUID-based IDs
          deviceName.isNotEmpty && 
          deviceName != 'Unknown Device' && 
          deviceName != 'Unknown' &&
          deviceName != finalDeviceId &&
          deviceName != macAddress &&
          !finalDeviceId.contains(':') && // Only for UUID-based IDs, not MAC addresses
          storedName == null) {
        unawaited(DeviceStorage.setDeviceDisplayName(finalDeviceId, deviceName));
        displayName = deviceName; // Use the discovered name immediately
        Logger.info('Storing discovered device name from native scan: $finalDeviceId -> $deviceName');
      }
      
      final device = DeviceModel(
        id: finalDeviceId, // Use UUID if available, otherwise use provided ID
        name: displayName, // Use stored name or discovered name
        address: macAddress, // Keep MAC for connection purposes (BLE requires MAC to connect)
        type: DeviceType.ble,
        rssi: rssi,
        lastSeen: DateTime.now(),
      );
      
      Logger.info('Native scan found device: $displayName (UUID: $finalDeviceId, MAC: $macAddress)');
      _nativeScanDevices[finalDeviceId] = device;
      _emitDiscoveredDevices();
      
      unawaited(_scanLogStorage.logEvent(
        'Native scan device found',
        metadata: {
          'deviceId': deviceId,
          'name': deviceName,
          'rssi': rssi,
          'matchedBy': result['matchedBy'],
        },
      ));
    }
  }

  // Handle peripheral connection state changes (when a central connects/disconnects from our GATT server)
  void _handlePeripheralConnectionState(Map<String, dynamic> state) {
    try {
      print('=== 🔵 [CONN_MGR] PERIPHERAL CONNECTION STATE EVENT ===');
      print('🔵 [CONN_MGR] State data: $state');
      Logger.info('=== 🔵 PERIPHERAL CONNECTION STATE EVENT ===');
      Logger.info('State data: $state');
      
      final isConnected = state['connected'] as bool? ?? false;
      final deviceAddress = state['deviceAddress'] as String? ?? '';
      final deviceName = state['deviceName'] as String? ?? 'Unknown Device';
      
      if (isConnected) {
        Logger.info('🔵 Central connected to our GATT server: $deviceName ($deviceAddress)');
        
        String? deviceUuid;
        
        // Strategy 1: Check UUID-MAC mapping storage FIRST (most reliable)
        deviceUuid = DeviceStorage.getUuidForMac(deviceAddress);
        if (deviceUuid != null) {
          Logger.info('✅ Found device UUID from UUID-MAC mapping: $deviceUuid');
        }
        
        // Strategy 2: Check discovered devices
        if (deviceUuid == null) {
          for (final device in _bleDevices) {
            if (device.address == deviceAddress && !device.id.contains(':')) {
              deviceUuid = device.id;
              // Store mapping for future use
              DeviceStorage.setMacForUuid(deviceUuid, deviceAddress);
              Logger.info('✅ Found device UUID from discovered devices: $deviceUuid');
              break;
            }
          }
        }
        
        // Strategy 3: Check native scan devices
        if (deviceUuid == null) {
          for (final device in _nativeScanDevices.values) {
            if (device.address == deviceAddress && !device.id.contains(':')) {
              deviceUuid = device.id;
              DeviceStorage.setMacForUuid(deviceUuid, deviceAddress);
              Logger.info('✅ Found device UUID from native scan: $deviceUuid');
              break;
            }
          }
        }
        
        // Strategy 4: Check messages for UUID associated with this MAC
        if (deviceUuid == null) {
          final allMessages = MessageStorage.getAllMessages();
          final sortedMessages = List<MessageModel>.from(allMessages);
          sortedMessages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
          
          for (final message in sortedMessages) {
            if (!message.isSent && !message.senderId.contains(':')) {
              // Check if we have any message from this UUID that mentions this MAC
              // This is indirect matching - if we received from a UUID and this MAC connects,
              // it might be the same device
              deviceUuid = message.senderId;
              DeviceStorage.setMacForUuid(deviceUuid, deviceAddress);
              Logger.info('✅ Found device UUID from messages: $deviceUuid');
              break;
            }
          }
        }
        
        // CRITICAL: Never use MAC as device ID - return early if UUID not found
        if (deviceUuid == null) {
          Logger.error('⚠️ Cannot find UUID for peripheral connection with MAC: $deviceAddress');
          Logger.error('⚠️ Skipping connection to prevent MAC-based device identification');
          return;
        }
        
        // Get stored name if available
        final storedName = DeviceStorage.getDeviceDisplayName(deviceUuid);
        final finalDeviceName = storedName ?? 
                                (deviceName != 'Unknown Device' ? deviceName : deviceUuid);
        
        // Create device model with UUID, never MAC
        final device = DeviceModel(
          id: deviceUuid, // UUID, never MAC
          name: finalDeviceName,
          address: deviceAddress, // MAC only for connection
          type: DeviceType.ble,
          isConnected: true,
        );
        
        // Update connection state
        _connectedDevice = device;
        _currentConnectionType = ConnectionType.ble;
        _isPeripheralConnection = true;  // Mark as peripheral connection
        _connectionController.add(ConnectionState.connected);
        
        print('✅✅✅ [CONN_MGR] Peripheral connection TRACKED: $finalDeviceName ($deviceUuid)');
        print('   [CONN_MGR] Device address: $deviceAddress');
        print('   [CONN_MGR] Connection type: peripheral (central connected to us)');
        Logger.info('✅✅✅ Peripheral connection TRACKED: $finalDeviceName ($deviceUuid)');
        Logger.info('   Device address: $deviceAddress');
        Logger.info('   Connection type: peripheral (central connected to us)');
        
        // Store device name if we got a proper name
        if (deviceName.isNotEmpty && 
            deviceName != 'Unknown Device' && 
            deviceName != deviceUuid &&
            !deviceUuid.contains(':')) {
          unawaited(DeviceStorage.setDeviceDisplayName(deviceUuid, deviceName));
        }
      } else {
        Logger.info('🔴 Central disconnected from our GATT server: $deviceName ($deviceAddress)');
        
        // Only disconnect if this was the connected device
        // Match by MAC address (since that's what we get from the event)
        if (_isPeripheralConnection && 
            _connectedDevice != null && 
            _connectedDevice!.address == deviceAddress) {
          _currentConnectionType = ConnectionType.none;
          _connectedDevice = null;
          _isPeripheralConnection = false;
          _connectionController.add(ConnectionState.disconnected);
          
          Logger.info('🔴 Peripheral connection closed');
        }
      }
    } catch (e, stackTrace) {
      Logger.error('❌ Error handling peripheral connection state', e, stackTrace);
    }
  }

  Future<void> stopScan() async {
    try {
      await _bluetoothService.stopScan();
      await _blePeripheralService.stopNativeScan();
      
      Logger.info('Device scan stopped');
      unawaited(_scanLogStorage.logEvent('Device scan stopped'));
      
      final shouldRestartAdvertising = await _shouldStopAdvertisingForScan();
      if (shouldRestartAdvertising && !_isAdvertising) {
        await _restartAdvertisingAfterScan();
      }
    } catch (e) {
      Logger.error('Error stopping device scan', e);
      final shouldRestartAdvertising = await _shouldStopAdvertisingForScan();
      if (shouldRestartAdvertising && !_isAdvertising) {
        unawaited(_restartAdvertisingAfterScan());
      }
    }
  }

  Future<bool> connectToDevice(DeviceModel device) async {
    try {
      // Stop any ongoing scan first to free up Bluetooth resources
      Logger.info('Stopping scan before connecting to ${device.name}');
      try {
        await stopScan();
        // Wait for Bluetooth resources to be fully released
        // This is especially important after Classic Discovery or native scanning
        await Future.delayed(const Duration(milliseconds: 500));
        Logger.info('Scan stopped, resources released');
      } catch (e) {
        Logger.warning('Error stopping scan before connect: $e');
        // Continue anyway - might not be scanning
      }

      bool connected = false;

      if (device.type == DeviceType.ble) {
        // Additional delay for BLE connections after scanning
        await Future.delayed(const Duration(milliseconds: 300));
        connected = await _bluetoothService.connectToDevice(device);
        if (connected) {
          _currentConnectionType = ConnectionType.ble;
          _isPeripheralConnection = false;  // This is a central connection
          final connectedDevice = _bluetoothService.getConnectedDevice();
          _connectedDevice = connectedDevice;
          
          // Store UUID-MAC mapping and device name
          if (connectedDevice != null) {
            final deviceUuid = connectedDevice.id;
            final deviceName = connectedDevice.name;
            
            // Store UUID-MAC mapping
            if (connectedDevice.address != null && !deviceUuid.contains(':')) {
              DeviceStorage.setMacForUuid(deviceUuid, connectedDevice.address!);
            }
            
            // Store device name if we got a proper name
            if (deviceUuid.isNotEmpty && 
                deviceName.isNotEmpty && 
                deviceName != 'Unknown Device' && 
                deviceName != deviceUuid &&
                !deviceUuid.contains(':')) { // Only store for UUID-based IDs, not MAC addresses
              final storedName = DeviceStorage.getDeviceDisplayName(deviceUuid);
              if (storedName == null || storedName == deviceUuid) {
                unawaited(DeviceStorage.setDeviceDisplayName(deviceUuid, deviceName));
                Logger.info('Stored device name after connection: $deviceUuid -> $deviceName');
              }
            }
          }
          
          // IMPORTANT: Restart advertising after connecting as central
          // This allows the other device to discover and connect back to us
          Logger.info('Connection successful. Restarting advertising so other device can connect back...');
          await Future.delayed(const Duration(milliseconds: 500)); // Small delay for connection to stabilize
          unawaited(_ensurePeripheralStarted()); // Restart advertising in background
        }
      } else if (device.type == DeviceType.wifiDirect) {
        connected = await _wifiDirectService.connectToDevice(device);
        if (connected) {
          _currentConnectionType = ConnectionType.wifiDirect;
          _connectedDevice = await _wifiDirectService.getConnectedDevice();
        }
      }

      if (connected && _connectedDevice != null) {
        _connectionController.add(ConnectionState.connected);
        Logger.info('Connected to device: ${device.name}');
      } else {
        _connectionController.add(ConnectionState.disconnected);
        Logger.error('Failed to connect to device: ${device.name}');
      }

      return connected;
    } catch (e) {
      Logger.error('Error connecting to device', e);
      _connectionController.add(ConnectionState.disconnected);
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      if (_currentConnectionType == ConnectionType.ble) {
        if (_isPeripheralConnection) {
          // For peripheral connections, we can't actively disconnect the central
          // The central will disconnect itself. We just clear our state.
          Logger.info('Clearing peripheral connection state (central will disconnect)');
        } else {
          // Central connection - actively disconnect
          await _bluetoothService.disconnect();
        }
      } else if (_currentConnectionType == ConnectionType.wifiDirect) {
        await _wifiDirectService.disconnect();
      }

      _currentConnectionType = ConnectionType.none;
      _connectedDevice = null;
      _isPeripheralConnection = false;
      _connectionController.add(ConnectionState.disconnected);
      
      // Restart advertising after disconnection so we can be discovered again
      Logger.info('Disconnected from device. Restarting advertising...');
      await Future.delayed(const Duration(milliseconds: 500));
      unawaited(_ensurePeripheralStarted());
      
      Logger.info('Disconnected from device');
    } catch (e) {
      Logger.error('Error disconnecting', e);
    }
  }

  Future<bool> sendMessage(String message) async {
    try {
      if (_currentConnectionType == ConnectionType.ble) {
        if (_isPeripheralConnection) {
          // We have a central connected to our GATT server → send via peripheral
          Logger.info('Sending message via peripheral (GATT server)');
          return await _blePeripheralService.sendMessage(message);
        } else {
          // We are central → use BluetoothService
          Logger.info('Sending message via central (BLE client)');
          return await _bluetoothService.sendMessage(message);
        }
      } else if (_currentConnectionType == ConnectionType.wifiDirect) {
        return await _wifiDirectService.sendMessage(message);
      } else {
        Logger.error('Not connected to any device');
        return false;
      }
    } catch (e) {
      Logger.error('Error sending message', e);
      return false;
    }
  }

  bool isConnected() {
    if (_currentConnectionType == ConnectionType.ble) {
      return _bluetoothService.isConnected();
    } else if (_currentConnectionType == ConnectionType.wifiDirect) {
      return _connectedDevice != null;
    }
    return false;
  }

  Stream<List<DeviceModel>> getDiscoveredDevices() {
    return _deviceStreamController.stream;
  }

  void dispose() {
    _bluetoothService.dispose();
    _wifiDirectService.dispose();
    _blePeripheralService.dispose();
    _bleDiscoverySubscription?.cancel();
    _wifiDiscoverySubscription?.cancel();
    _nativeScanSubscription?.cancel();
    _peripheralConnectionStateSubscription?.cancel();
    _connectionController.close();
    _messageController.close();
    _deviceStreamController.close();
  }

  void _emitDiscoveredDevices() {
    final Map<String, DeviceModel> combined = {};
    
    // Add devices from all sources
    for (final device in _bleDevices) {
      combined[device.id] = device;
    }
    for (final device in _wifiDevices) {
      combined[device.id] = device;
    }
    // Native scan devices have priority (most recent)
    for (final device in _nativeScanDevices.values) {
      combined[device.id] = device;
    }
    
    _deviceStreamController.add(combined.values.toList());
  }

  Future<void> _ensurePeripheralStarted() async {
    if (_isAdvertising) return;
    try {
      if (!_peripheralInitialized) {
        // Get device UUID for inclusion in BLE advertisements
        final deviceUuid = DeviceStorage.getDeviceId();
        Logger.info('Initializing BLE peripheral with device UUID: $deviceUuid');
        
        _peripheralInitialized = await _blePeripheralService.initialize(
          serviceUuid: AppConstants.bleServiceUuid,
          characteristicUuid: AppConstants.bleCharacteristicUuid,
          deviceUuid: deviceUuid,
        );
        
        // IMPORTANT: Ensure connection state listener is active after initialization
        // The EventChannel stream is set up in BlePeripheralService.initialize(),
        // so we just need to listen to it here
        if (_peripheralInitialized) {
          // Cancel existing subscription if any
          _peripheralConnectionStateSubscription?.cancel();
          // Listen to the connection state stream (EventChannel is now active)
          print('🔵 [CONN_MGR] Setting up connection state listener in ConnectionManager...');
          Logger.info('🔵 Setting up connection state listener in ConnectionManager...');
          _peripheralConnectionStateSubscription = _blePeripheralService.connectionState.listen(
            (state) {
              print('🔵🔵 [CONN_MGR] Connection state event received: $state');
              Logger.info('🔵🔵 Connection state event received in ConnectionManager: $state');
              _handlePeripheralConnectionState(state);
            },
            onError: (error) {
              Logger.error('❌ Error in peripheral connection state stream', error);
            },
            onDone: () {
              Logger.warning('🔵 Connection state stream closed in ConnectionManager');
            },
          );
          Logger.info('✅ Peripheral connection state listener set up in ConnectionManager');
        }
        
        if (_peripheralInitialized && !_peripheralListening) {
          _blePeripheralService.incomingMessages.listen((message) {
            Logger.info('Message received via BlePeripheralService (peripheral): $message');
            _messageController.add(message);
          });
          _peripheralListening = true;
          Logger.info('BLE peripheral message listener set up');
        }
      }

      if (!_peripheralInitialized) {
        Logger.warning('BLE peripheral not initialized');
        return;
      }

      final deviceName = await _resolveDeviceName();
      final started = await _blePeripheralService.startAdvertising(
        deviceName: deviceName,
      );
      _isAdvertising = started;
      if (!started) {
        Logger.warning('Failed to start BLE advertising');
      }
    } catch (e) {
      Logger.error('Error setting up BLE peripheral', e);
    }
  }

  Future<String> _resolveDeviceName() async {
    try {
      // First, check if user has set a display name
      final displayName = DeviceStorage.getDisplayName();
      if (displayName != null && displayName.isNotEmpty) {
        return displayName;
      }
      
      // Fallback to device model name
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        final model = info.model;
        return 'Offlink $model';
      }
      return 'Offlink Device';
    } catch (e) {
      Logger.warning('Unable to resolve device name: $e');
      return 'Offlink Device';
    }
  }

  /// Restart advertising with updated device name
  Future<void> restartAdvertising() async {
    try {
      await _stopAdvertising();
      await Future.delayed(const Duration(milliseconds: 200));
      await _ensurePeripheralStarted();
    } catch (e) {
      Logger.error('Error restarting advertising', e);
    }
  }

  /// Stop advertising (private helper)
  Future<void> _stopAdvertising() async {
    try {
      await _blePeripheralService.stopAdvertising();
      _isAdvertising = false;
    } catch (e) {
      Logger.error('Error stopping advertising', e);
    }
  }

  Future<bool> _shouldStopAdvertisingForScan() async {
    if (!Platform.isAndroid) return false;
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      return androidInfo.version.sdkInt >= 31;
    } catch (e) {
      return true;
    }
  }

  Future<int> _getScanDelayForDevice() async {
    if (!Platform.isAndroid) return 1000;
    
    try {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final manufacturer = androidInfo.manufacturer.toLowerCase();
      final model = androidInfo.model.toLowerCase();
      final brand = androidInfo.brand.toLowerCase();
      
      Logger.info('Device: manufacturer=$manufacturer, model=$model, brand=$brand');
      
      // TECNO devices need very long delays
      final isTecno = manufacturer.contains('tecno') || 
                      model.contains('tecno') || 
                      brand.contains('tecno') ||
                      manufacturer.contains('transsion') ||
                      model.contains('cla') ||
                      model.contains('camon');
      
      if (isTecno) {
        Logger.info('Detected TECNO device - using 6000ms delay');
        return 6000;
      }
      
      final problematicBrands = ['infinix', 'itel', 'realme', 'oppo', 'vivo', 'xiaomi', 'redmi', 'poco'];
      
      for (final brandName in problematicBrands) {
        if (manufacturer.contains(brandName) || model.contains(brandName) || brand.contains(brandName)) {
          Logger.info('Detected $brandName device - using 4000ms delay');
          return 4000;
        }
      }
      
      return 2500;
    } catch (e) {
      Logger.warning('Error detecting device: $e');
      return 5000;
    }
  }

  Future<void> _restartAdvertisingAfterScan() async {
    try {
      Logger.info('Resuming peripheral role after scan');
      await Future.delayed(const Duration(milliseconds: 500));
      
      final shouldResumeGattServer = await _shouldStopAdvertisingForScan();
      if (shouldResumeGattServer) {
        final resumed = await _blePeripheralService.resumeAfterScanning();
        if (!resumed) {
          Logger.error('Failed to resume GATT server');
          _peripheralInitialized = false;
        }
      }
      
      final deviceName = await _resolveDeviceName();
      final started = await _blePeripheralService.startAdvertising(deviceName: deviceName);
      _isAdvertising = started;
      if (started) {
        Logger.info('Peripheral role resumed successfully');
      } else {
        Logger.warning('Failed to resume advertising');
      }
    } catch (e) {
      Logger.error('Error resuming peripheral role', e);
      _isAdvertising = false;
    }
  }
}

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}