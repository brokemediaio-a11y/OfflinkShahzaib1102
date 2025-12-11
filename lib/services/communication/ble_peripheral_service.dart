import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../../utils/logger.dart';

class BlePeripheralService {
  static final BlePeripheralService _instance = BlePeripheralService._internal();
  factory BlePeripheralService() => _instance;
  BlePeripheralService._internal();

  static const _channel = MethodChannel('com.offlink.ble_peripheral');
  static const _messageChannel = EventChannel('com.offlink.ble_peripheral/messages');
  static const _scanResultChannel = EventChannel('com.offlink.ble_peripheral/scan_results');
  
  final _messageController = StreamController<String>.broadcast();
  final _scanResultController = StreamController<Map<String, dynamic>>.broadcast();
  
  StreamSubscription? _messageSubscription;
  StreamSubscription? _scanResultSubscription;
  
  bool _initialized = false;

  Stream<String> get incomingMessages => _messageController.stream;
  Stream<Map<String, dynamic>> get scanResults => _scanResultController.stream;

  Future<bool> initialize({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    if (!Platform.isAndroid) {
      Logger.warning('BLE peripheral only supported on Android');
      return false;
    }
    
    try {
      final result = await _channel.invokeMethod<bool>('initialize', {
        'serviceUuid': serviceUuid,
        'characteristicUuid': characteristicUuid,
      });
      
      _initialized = result ?? false;
      
      if (_initialized) {
        // Set up message listener
        _messageSubscription?.cancel();
        _messageSubscription = _messageChannel.receiveBroadcastStream().listen(
          (message) {
            if (message is String) {
              _messageController.add(message);
            }
          },
          onError: (error) {
            Logger.error('Error in message stream', error);
          },
        );
        
        // Set up scan result listener
        _scanResultSubscription?.cancel();
        _scanResultSubscription = _scanResultChannel.receiveBroadcastStream().listen(
          (result) {
            if (result is Map) {
              _scanResultController.add(Map<String, dynamic>.from(result));
            }
          },
          onError: (error) {
            Logger.error('Error in scan result stream', error);
          },
        );
        
        Logger.info('BLE peripheral service initialized');
      }
      
      return _initialized;
    } catch (e) {
      Logger.error('Error initializing BLE peripheral service', e);
      return false;
    }
  }

  Future<bool> startAdvertising({String? deviceName}) async {
    if (!_initialized) {
      Logger.warning('BLE peripheral not initialized');
      return false;
    }
    
    try {
      final result = await _channel.invokeMethod<bool>('startAdvertising', {
        'deviceName': deviceName,
      });
      return result ?? false;
    } catch (e) {
      Logger.error('Error starting advertising', e);
      return false;
    }
  }

  Future<void> stopAdvertising() async {
    try {
      await _channel.invokeMethod('stopAdvertising');
    } catch (e) {
      Logger.error('Error stopping advertising', e);
    }
  }

  Future<void> suspendForScanning() async {
    try {
      await _channel.invokeMethod('suspendForScanning');
    } catch (e) {
      Logger.error('Error suspending for scanning', e);
      rethrow;
    }
  }

  Future<bool> resumeAfterScanning() async {
    try {
      final result = await _channel.invokeMethod<bool>('resumeAfterScanning');
      return result ?? false;
    } catch (e) {
      Logger.error('Error resuming after scanning', e);
      return false;
    }
  }

  Future<bool> sendMessage(String message) async {
    try {
      final result = await _channel.invokeMethod<bool>('sendMessage', {
        'message': message,
      });
      return result ?? false;
    } catch (e) {
      Logger.error('Error sending message via peripheral', e);
      return false;
    }
  }
  
  // ==================== NATIVE SCANNER METHODS ====================
  
  /// Start native BLE scan (bypasses flutter_blue_plus)
  /// Returns a map with 'success' boolean and optionally 'error' string
  Future<Map<String, dynamic>> startNativeScan({int timeoutMs = 30000}) async {
    try {
      Logger.info('Starting native BLE scan (timeout: ${timeoutMs}ms)');
      final result = await _channel.invokeMethod<Map>('startNativeScan', {
        'timeoutMs': timeoutMs,
      });
      
      if (result != null) {
        final resultMap = Map<String, dynamic>.from(result);
        Logger.info('Native scan start result: $resultMap');
        return resultMap;
      }
      
      return {'success': false, 'error': 'No result from native scan'};
    } catch (e) {
      Logger.error('Error starting native scan', e);
      return {'success': false, 'error': e.toString()};
    }
  }
  
  /// Stop native BLE scan
  Future<void> stopNativeScan() async {
    try {
      Logger.info('Stopping native BLE scan');
      await _channel.invokeMethod('stopNativeScan');
    } catch (e) {
      Logger.error('Error stopping native scan', e);
    }
  }
  
  /// Check if native scan is running
  Future<bool> isNativeScanning() async {
    try {
      final result = await _channel.invokeMethod<bool>('isNativeScanning');
      return result ?? false;
    } catch (e) {
      Logger.error('Error checking native scan status', e);
      return false;
    }
  }

  void dispose() {
    _messageSubscription?.cancel();
    _scanResultSubscription?.cancel();
    _messageController.close();
    _scanResultController.close();
  }
}