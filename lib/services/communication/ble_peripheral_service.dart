import 'dart:async';
import 'package:flutter/services.dart';
import '../../utils/logger.dart';

class BlePeripheralService {
  static final BlePeripheralService _instance = BlePeripheralService._internal();
  factory BlePeripheralService() => _instance;
  BlePeripheralService._internal();

  static const MethodChannel _channel =
      MethodChannel('com.offlink.ble_peripheral');
  static const EventChannel _eventChannel =
      EventChannel('com.offlink.ble_peripheral/messages');

  final _messageController = StreamController<String>.broadcast();
  StreamSubscription<dynamic>? _eventSubscription;
  bool _initialized = false;

  Stream<String> get incomingMessages => _messageController.stream;

  Future<bool> initialize({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    if (_initialized) return true;
    try {
      final result = await _channel.invokeMethod<bool>('initialize', {
        'serviceUuid': serviceUuid,
        'characteristicUuid': characteristicUuid,
      });
      _initialized = result ?? false;
      if (_initialized) {
        _eventSubscription ??=
            _eventChannel.receiveBroadcastStream().listen((event) {
          if (event is String) {
            _messageController.add(event);
          }
        }, onError: (error) {
          Logger.error('BLE peripheral event error', error);
        });
      }
      return _initialized;
    } on MissingPluginException {
      Logger.warning('BLE peripheral plugin not available on this platform');
      return false;
    } catch (e) {
      Logger.error('Error initializing BLE peripheral', e);
      return false;
    }
  }

  Future<bool> startAdvertising({required String deviceName}) async {
    try {
      final result = await _channel.invokeMethod<bool>('startAdvertising', {
        'deviceName': deviceName,
      });
      return result ?? false;
    } catch (e) {
      Logger.error('Error starting BLE advertising', e);
      return false;
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await _channel.invokeMethod('stopAdvertising');
    } catch (e) {
      Logger.error('Error stopping BLE advertising', e);
    }
  }

  Future<bool> sendMessage(String message) async {
    try {
      final result = await _channel.invokeMethod<bool>('sendMessage', {
        'message': message,
      });
      return result ?? false;
    } catch (e) {
      Logger.error('Error sending BLE peripheral message', e);
      return false;
    }
  }

  void dispose() {
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _messageController.close();
  }
}

