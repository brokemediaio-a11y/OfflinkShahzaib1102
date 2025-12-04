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

  bool _peripheralInitialized = false;
  bool _peripheralListening = false;
  bool _isAdvertising = false;
  bool _isInitialized = false;

  StreamSubscription<List<DeviceModel>>? _bleDiscoverySubscription;
  StreamSubscription<List<DeviceModel>>? _wifiDiscoverySubscription;

  Stream<ConnectionState> get connectionState => _connectionController.stream;
  Stream<String> get incomingMessages => _messageController.stream;

  ConnectionType get currentConnectionType => _currentConnectionType;
  DeviceModel? get connectedDevice => _connectedDevice;

  // Initialize both services
  Future<bool> initialize() async {
    if (_isInitialized) {
      await _ensurePeripheralStarted();
      return true;
    }
    try {
      final bleInitialized = await _bluetoothService.initialize();
      final wifiInitialized = await _wifiDirectService.initialize();

      // Set up message listeners
      // BluetoothService: for when we're the central (scanning/connecting)
      _bluetoothService.incomingMessages.listen((message) {
        Logger.info('Message received via BluetoothService (central): $message');
        _messageController.add(message);
      });

      // Note: BlePeripheralService listener is set up in _ensurePeripheralStarted()
      // after the service is initialized, to ensure the EventChannel is ready

      _wifiDirectService.incomingMessages.listen((message) {
        _messageController.add(message);
      });

      final initialized = bleInitialized || wifiInitialized;
      Logger.info(
          'Connection manager initialized (BLE: $bleInitialized, Wi-Fi Direct: $wifiInitialized)');
      unawaited(_scanLogStorage.logEvent(
        'Connection manager initialized',
        metadata: {'ble': bleInitialized, 'wifiDirect': wifiInitialized},
      ));

      if (initialized) {
        _isInitialized = true;
        if (bleInitialized) {
          // Fire and forget; errors are logged inside _ensurePeripheralStarted.
          unawaited(_ensurePeripheralStarted());
        }
      }

      return initialized;
    } catch (e) {
      Logger.error('Error initializing connection manager', e);
      unawaited(_scanLogStorage.logEvent(
        'Connection manager init failure',
        metadata: {'error': e.toString()},
      ));
      return false;
    }
  }

  // Start scanning for devices (both BLE and Wi-Fi Direct)
  Future<void> startScan({bool useBle = true, bool useWifiDirect = false}) async {
    try {
      await _ensurePeripheralStarted();
      if (useBle) {
        await _bluetoothService.startScan();
      }
      // Wi-Fi Direct is disabled for now - requires native Android implementation
      // if (useWifiDirect) {
      //   await _wifiDirectService.startScan();
      // }
      Logger.info('Device scan started (BLE: $useBle, Wi-Fi Direct: disabled)');
      unawaited(_scanLogStorage.logEvent(
        'Device scan started',
        metadata: {'ble': useBle, 'wifiDirect': false},
      ));
    } catch (e) {
      Logger.error('Error starting device scan', e);
      unawaited(_scanLogStorage.logEvent(
        'Device scan start failure',
        metadata: {'error': e.toString()},
      ));
      rethrow;
    }
  }

  // Stop scanning
  Future<void> stopScan() async {
    try {
      await _bluetoothService.stopScan();
      // Wi-Fi Direct disabled
      // await _wifiDirectService.stopScan();
      Logger.info('Device scan stopped');
      unawaited(_scanLogStorage.logEvent('Device scan stopped'));
    } catch (e) {
      Logger.error('Error stopping device scan', e);
      unawaited(_scanLogStorage.logEvent(
        'Device scan stop failure',
        metadata: {'error': e.toString()},
      ));
    }
  }

  // Connect to device (automatically chooses BLE or Wi-Fi Direct)
  Future<bool> connectToDevice(DeviceModel device) async {
    try {
      bool connected = false;

      if (device.type == DeviceType.ble) {
        connected = await _bluetoothService.connectToDevice(device);
        if (connected) {
          _currentConnectionType = ConnectionType.ble;
          _connectedDevice = _bluetoothService.getConnectedDevice();
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
        unawaited(_scanLogStorage.logEvent(
          'Device connected',
          metadata: {
            'deviceId': _connectedDevice!.id,
            'name': _connectedDevice!.name,
            'connectionType': _currentConnectionType.name,
          },
        ));
      } else {
        _connectionController.add(ConnectionState.disconnected);
        Logger.error('Failed to connect to device: ${device.name}');
        unawaited(_scanLogStorage.logEvent(
          'Device connection failed',
          metadata: {
            'deviceId': device.id,
            'name': device.name,
            'connectionType': device.type.name,
          },
        ));
      }

      return connected;
    } catch (e) {
      Logger.error('Error connecting to device', e);
      _connectionController.add(ConnectionState.disconnected);
      return false;
    }
  }

  // Disconnect from device
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
      Logger.info('Disconnected from device');
      unawaited(_scanLogStorage.logEvent('Device disconnected'));
    } catch (e) {
      Logger.error('Error disconnecting', e);
      unawaited(_scanLogStorage.logEvent(
        'Device disconnect failure',
        metadata: {'error': e.toString()},
      ));
    }
  }

  // Send message
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

  // Check if connected
  bool isConnected() {
    if (_currentConnectionType == ConnectionType.ble) {
      return _bluetoothService.isConnected();
    } else if (_currentConnectionType == ConnectionType.wifiDirect) {
      // Wi-Fi Direct connection check is async, so we'll use a cached value
      return _connectedDevice != null;
    }
    return false;
  }

  // Get discovered devices from both services
  Stream<List<DeviceModel>> getDiscoveredDevices() {
    return _deviceStreamController.stream;
  }

  // Dispose
  void dispose() {
    _bluetoothService.dispose();
    _wifiDirectService.dispose();
    _blePeripheralService.dispose();
    _bleDiscoverySubscription?.cancel();
    _wifiDiscoverySubscription?.cancel();
    _connectionController.close();
    _messageController.close();
    _deviceStreamController.close();
  }

  void _emitDiscoveredDevices() {
    final Map<String, DeviceModel> combined = {};
    for (final device in [..._bleDevices, ..._wifiDevices]) {
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
          // Set up listener for incoming messages from peripheral service
          // This is for when we're the peripheral (advertising/receiving connections)
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
        unawaited(_scanLogStorage.logEvent(
          'BLE peripheral initialization failed',
          metadata: {'reason': 'not_supported_or_permission'},
        ));
        return;
      }

      final deviceName = await _resolveDeviceName();
      final started = await _blePeripheralService.startAdvertising(
        deviceName: deviceName,
      );
      _isAdvertising = started;
      if (!started) {
        Logger.warning('Failed to start BLE advertising');
        unawaited(_scanLogStorage.logEvent(
          'BLE peripheral advertising failed',
          metadata: {'deviceName': deviceName},
        ));
      } else {
        unawaited(_scanLogStorage.logEvent(
          'BLE peripheral advertising started',
          metadata: {'deviceName': deviceName},
        ));
      }
    } catch (e) {
      Logger.error('Error setting up BLE peripheral', e);
      unawaited(_scanLogStorage.logEvent(
        'BLE peripheral setup failure',
        metadata: {'error': e.toString()},
      ));
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
}

enum ConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

