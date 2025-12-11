import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../utils/logger.dart';
import '../storage/scan_log_storage.dart';
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

  StreamSubscription<List<DeviceModel>>? _bleDiscoverySubscription;
  StreamSubscription<List<DeviceModel>>? _wifiDiscoverySubscription;
  StreamSubscription<Map<String, dynamic>>? _nativeScanSubscription;

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
      final device = DeviceModel(
        id: deviceId,
        name: deviceName,
        address: deviceId,
        type: DeviceType.ble,
        rssi: rssi,
        lastSeen: DateTime.now(),
      );
      
      Logger.info('Native scan found device: $deviceName ($deviceId)');
      _nativeScanDevices[deviceId] = device;
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
          _connectedDevice = _bluetoothService.getConnectedDevice();
          
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
        await _bluetoothService.disconnect();
      } else if (_currentConnectionType == ConnectionType.wifiDirect) {
        await _wifiDirectService.disconnect();
      }

      _currentConnectionType = ConnectionType.none;
      _connectedDevice = null;
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
        return await _bluetoothService.sendMessage(message);
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
        _peripheralInitialized = await _blePeripheralService.initialize(
          serviceUuid: AppConstants.bleServiceUuid,
          characteristicUuid: AppConstants.bleCharacteristicUuid,
        );
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