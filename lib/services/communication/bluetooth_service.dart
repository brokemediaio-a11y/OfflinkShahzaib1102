import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../../models/device_model.dart';
import '../../core/constants.dart';
import '../../utils/logger.dart';
import '../storage/scan_log_storage.dart';

class BluetoothService {
  static final BluetoothService _instance = BluetoothService._internal();
  factory BluetoothService() => _instance;
  BluetoothService._internal();

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _characteristic;
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
      final isAvailable = await FlutterBluePlus.isSupported;
      if (!isAvailable) {
        Logger.warning('Bluetooth is not available');
        return false;
      }

      // Check if Bluetooth is on
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
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
  Future<void> startScan() async {
    try {
      await initialize();

      // Verify Bluetooth is still on
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
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
        },
      );
      final targetServiceUuid = AppConstants.bleServiceUuid.toUpperCase();
      
      Logger.info('Starting BLE scan (scanning all devices, filtering in code)');
      Logger.info('Target service UUID: $targetServiceUuid');
      
      // IMPORTANT: Scan WITHOUT the withServices filter
      // The filter can be too strict and prevent results from coming through
      // We'll filter in code instead to see ALL devices and their service UUIDs
      await FlutterBluePlus.startScan(
        timeout: AppConstants.bleScanTimeout,
        // Removed withServices filter to see all devices
        androidScanMode: AndroidScanMode.lowLatency,
      );
      
      Logger.info('BLE scan started (no filter - will filter in code)');
      
      // Reset scan diagnostics
      _totalScanResultsReceived = 0;
      
      // Set up diagnostics timer to check if we're getting any results
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
        } else {
          Logger.info('Scan diagnostics: Received $_totalScanResultsReceived total results');
          unawaited(_scanLogStorage.logEvent(
            'Scan diagnostics: Results received',
            metadata: {
              'totalResults': _totalScanResultsReceived,
              'discoveredDevices': _discoveredDevices.length,
            },
          ));
        }
      });

      // Listen to scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        _totalScanResultsReceived += results.length;
        Logger.debug('Scan results received: ${results.length} devices');
        unawaited(_scanLogStorage.logEvent(
          'Scan results batch',
          metadata: {'count': results.length},
        ));

        for (var result in results) {
          final deviceId = result.device.remoteId.str;
          final deviceName = result.device.platformName.isNotEmpty
              ? result.device.platformName
              : 'Unknown Device';
          
          // Log EVERY device found for debugging
          final serviceUuids = result.advertisementData.serviceUuids
              .map((u) => u.str.toUpperCase())
              .toList();
          
          Logger.debug(
            'BLE scan result: id=$deviceId name=$deviceName rssi=${result.rssi} '
            'serviceUuids=$serviceUuids',
          );
          
          unawaited(_scanLogStorage.logEvent(
            'BLE scan result',
            metadata: {
              'deviceId': deviceId,
              'name': deviceName,
              'rssi': result.rssi,
              'serviceUuids': serviceUuids.join(','),
              'hasTargetService': serviceUuids.contains(targetServiceUuid),
            },
          ));

          final device = DeviceModel(
            id: deviceId,
            name: deviceName,
            address: deviceId,
            type: DeviceType.ble,
            rssi: result.rssi,
            lastSeen: DateTime.now(),
          );

          // Check if this device matches our target service UUID
          final matchesTargetService = serviceUuids.contains(targetServiceUuid);
          
          // FALLBACK: Also check if device name starts with "Offlink" 
          // (in case service UUID is not being broadcast correctly)
          final matchesByName = deviceName.toLowerCase().startsWith('offlink');
          
          // Check if this is an Offlink device (by service UUID OR by name)
          if (matchesTargetService || matchesByName) {
            final isNewDevice = !_discoveredDevices.containsKey(device.id);
            _discoveredDevices[device.id] = device;
            _deviceController.add(_discoveredDevices.values.toList());

            Logger.info('Found Offlink device: $deviceName (${device.id}) - matched by ${matchesTargetService ? "service UUID" : "name"}');
            unawaited(_scanLogStorage.logEvent(
              'BLE device discovered (Offlink)',
              metadata: {
                'deviceId': device.id,
                'name': device.name,
                'rssi': result.rssi,
                'new': isNewDevice,
                'matchedBy': matchesTargetService ? 'serviceUuid' : 'name',
                'hasServiceUuid': matchesTargetService,
              },
            ));
          } else {
            // Log non-Offlink devices for debugging but don't add them
            final isNewDevice = !_discoveredDevices.containsKey(device.id);
            if (isNewDevice) {
              Logger.debug('Found non-Offlink BLE device: $deviceName (${device.id}) - filtering out');
            }
          }
        }
      }, onError: (error) {
        Logger.error('Error during BLE scan', error);
        unawaited(_scanLogStorage.logEvent(
          'BLE scan error',
          metadata: {'error': error.toString()},
        ));
      });

      Logger.info('BLE scan started');
      await _scanLogStorage.logEvent('BLE scan started');
    } catch (e) {
      Logger.error('Error starting BLE scan', e);
      unawaited(_scanLogStorage.logEvent(
        'BLE scan start failure',
        metadata: {'error': e.toString()},
      ));
      rethrow;
    }
  }

  // Stop scanning
  Future<void> stopScan() async {
    try {
      _scanDiagnosticsTimer?.cancel();
      _scanDiagnosticsTimer = null;
      
      await FlutterBluePlus.stopScan();
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
      final bluetoothDevice = BluetoothDevice.fromId(device.address);

      // Connect to device
      await bluetoothDevice.connect(
        timeout: AppConstants.connectionTimeout,
        autoConnect: false,
      );

      _connectedDevice = bluetoothDevice;

      // Discover services
      final services = await bluetoothDevice.discoverServices();
      
      // Find our service and characteristic
      for (var service in services) {
        if (service.uuid.toString().toUpperCase() ==
            AppConstants.bleServiceUuid.toUpperCase()) {
          for (var characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toUpperCase() ==
                AppConstants.bleCharacteristicUuid.toUpperCase()) {
              _characteristic = characteristic;

              // Subscribe to notifications
              await characteristic.setNotifyValue(true);
              
              // Listen for incoming messages
              _messageSubscription = characteristic.onValueReceived.listen(
                (value) {
                  final message = String.fromCharCodes(value);
                  _messageController.add(message);
                  Logger.debug('Received message via BLE: $message');
                },
              );

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

      Logger.warning('Service or characteristic not found');
      unawaited(_scanLogStorage.logEvent(
        'BLE connect failure - characteristic not found',
        metadata: {'deviceId': device.id, 'name': device.name},
      ));
      return false;
    } catch (e) {
      Logger.error('Error connecting to device', e);
      unawaited(_scanLogStorage.logEvent(
        'BLE connect failure',
        metadata: {'deviceId': device.id, 'name': device.name, 'error': e.toString()},
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
    
    // Get the actual device name
    final deviceName = _connectedDevice!.platformName.isNotEmpty
        ? _connectedDevice!.platformName
        : 'Offlink Device'; // Fallback name
    
    return DeviceModel(
      id: _connectedDevice!.remoteId.str,
      name: deviceName,
      address: _connectedDevice!.remoteId.str,
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

