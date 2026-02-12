import 'dart:async';
import 'dart:io';
import '../../models/device_model.dart';
import '../../utils/logger.dart';
import '../storage/scan_log_storage.dart';
import '../storage/device_storage.dart';
import 'package:flutter/services.dart';

class ClassicBluetoothService {
  static final ClassicBluetoothService _instance = ClassicBluetoothService._internal();
  factory ClassicBluetoothService() => _instance;
  ClassicBluetoothService._internal();

  static const MethodChannel _channel = MethodChannel('com.offlink.classic_bluetooth');
  static const EventChannel _messageChannel = EventChannel('com.offlink.classic_bluetooth/messages');
  static const EventChannel _connectionStateChannel = EventChannel('com.offlink.classic_bluetooth/connection_state');

  StreamSubscription? _messageSubscription;
  StreamSubscription? _connectionStateSubscription;

  final _messageController = StreamController<String>.broadcast();
  final _connectionStateController = StreamController<Map<String, dynamic>>.broadcast();
  final ScanLogStorage _scanLogStorage = ScanLogStorage.instance;

  DeviceModel? _connectedDevice;
  bool _isConnected = false;

  Stream<String> get incomingMessages => _messageController.stream;
  Stream<Map<String, dynamic>> get connectionState => _connectionStateController.stream;

  DeviceModel? get connectedDevice => _connectedDevice;
  bool get isConnected => _isConnected;

  Future<bool> initialize() async {
    if (!Platform.isAndroid) {
      Logger.warning('Classic Bluetooth only supported on Android');
      return false;
    }

    try {
      // Set up message listener
      _messageSubscription?.cancel();
      _messageSubscription = _messageChannel.receiveBroadcastStream().listen(
        (message) {
          if (message is String) {
            _messageController.add(message);
            Logger.info('Message received via Classic Bluetooth: $message');
          }
        },
        onError: (error) {
          Logger.error('Error in Classic Bluetooth message stream', error);
        },
      );

      // Set up connection state listener
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = _connectionStateChannel.receiveBroadcastStream().listen(
        (state) {
          if (state is Map) {
            _connectionStateController.add(Map<String, dynamic>.from(state));
            _handleConnectionState(Map<String, dynamic>.from(state));
          }
        },
        onError: (error) {
          Logger.error('Error in Classic Bluetooth connection state stream', error);
        },
      );

      Logger.info('Classic Bluetooth service initialized');
      return true;
    } catch (e) {
      Logger.error('Error initializing Classic Bluetooth service', e);
      return false;
    }
  }

  void _handleConnectionState(Map<String, dynamic> state) {
    final isConnected = state['connected'] as bool? ?? false;
    final deviceAddress = state['deviceAddress'] as String? ?? '';
    final deviceName = state['deviceName'] as String? ?? 'Unknown Device';

    _isConnected = isConnected;

    if (isConnected) {
      // Try to get UUID from storage
      String? deviceUuid = DeviceStorage.getUuidForMac(deviceAddress);
      
      // If no UUID found, use MAC as ID (Classic Bluetooth uses MAC addresses)
      final deviceId = deviceUuid ?? deviceAddress;

      _connectedDevice = DeviceModel(
        id: deviceId,
        name: deviceName,
        address: deviceAddress,
        type: DeviceType.classicBluetooth,
        isConnected: true,
      );

      Logger.info('Classic Bluetooth connected to: $deviceName ($deviceAddress)');
    } else {
      _connectedDevice = null;
      Logger.info('Classic Bluetooth disconnected');
    }
  }

  Future<bool> connectToDevice(DeviceModel device) async {
    try {
      if (device.address == null || device.address!.isEmpty) {
        Logger.error('Cannot connect: device has no MAC address');
        return false;
      }

      Logger.info('Connecting to device via Classic Bluetooth: ${device.name} (${device.address})');

      final result = await _channel.invokeMethod<bool>('connect', {
        'address': device.address,
      });

      if (result == true) {
        Logger.info('Classic Bluetooth connection established to ${device.name}');
        unawaited(_scanLogStorage.logEvent(
          'Classic Bluetooth device connected',
          metadata: {
            'deviceId': device.id,
            'name': device.name,
            'address': device.address,
          },
        ));
        return true;
      } else {
        Logger.error('Failed to connect via Classic Bluetooth');
        return false;
      }
    } catch (e) {
      Logger.error('Error connecting via Classic Bluetooth', e);
      unawaited(_scanLogStorage.logEvent(
        'Classic Bluetooth connect failure',
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

  Future<void> disconnect() async {
    try {
      await _channel.invokeMethod('disconnect');
      _connectedDevice = null;
      _isConnected = false;
      Logger.info('Disconnected from Classic Bluetooth device');
      unawaited(_scanLogStorage.logEvent('Classic Bluetooth device disconnected'));
    } catch (e) {
      Logger.error('Error disconnecting Classic Bluetooth', e);
    }
  }

  Future<bool> sendMessage(String message) async {
    try {
      if (!_isConnected) {
        Logger.error('Not connected to any device via Classic Bluetooth');
        unawaited(_scanLogStorage.logEvent(
          'Classic Bluetooth message send failure',
          metadata: {'reason': 'not_connected'},
        ));
        return false;
      }

      final result = await _channel.invokeMethod<bool>('sendMessage', {
        'message': message,
      });

      if (result == true) {
        Logger.debug('Message sent via Classic Bluetooth: $message');
        unawaited(_scanLogStorage.logEvent(
          'Classic Bluetooth message sent',
          metadata: {'length': message.length, 'preview': message},
        ));
        return true;
      } else {
        Logger.error('Failed to send message via Classic Bluetooth');
        return false;
      }
    } catch (e) {
      Logger.error('Error sending message via Classic Bluetooth', e);
      unawaited(_scanLogStorage.logEvent(
        'Classic Bluetooth message send failure',
        metadata: {'error': e.toString()},
      ));
      return false;
    }
  }

  void dispose() {
    _messageSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _messageController.close();
    _connectionStateController.close();
    disconnect();
  }
}
