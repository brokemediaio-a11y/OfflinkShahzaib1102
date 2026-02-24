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
  static const _connectionStateChannel = EventChannel('com.offlink.ble_peripheral/connection_state');
  
  final _messageController = StreamController<String>.broadcast();
  final _scanResultController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionStateController = StreamController<Map<String, dynamic>>.broadcast();
  
  StreamSubscription? _messageSubscription;
  StreamSubscription? _scanResultSubscription;
  StreamSubscription? _connectionStateSubscription;
  
  bool _initialized = false;

  Stream<String> get incomingMessages => _messageController.stream;
  Stream<Map<String, dynamic>> get scanResults => _scanResultController.stream;
  Stream<Map<String, dynamic>> get connectionState => _connectionStateController.stream;

  Future<bool> initialize({
    required String serviceUuid,
    required String characteristicUuid,
    String? deviceUuid,
  }) async {
    if (!Platform.isAndroid) {
      Logger.warning('BLE peripheral only supported on Android');
      return false;
    }
    
    try {
      final result = await _channel.invokeMethod<bool>('initialize', {
        'serviceUuid': serviceUuid,
        'characteristicUuid': characteristicUuid,
        'deviceUuid': deviceUuid,
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
        
        // Set up connection state listener
        _connectionStateSubscription?.cancel();
        print('🔵 [BLE_PERIPHERAL] Setting up connection state EventChannel listener...');
        Logger.info('🔵 Setting up connection state EventChannel listener...');
        
        // Try to set up the listener with error handling
        try {
          _connectionStateSubscription = _connectionStateChannel.receiveBroadcastStream().listen(
            (state) {
              print('🔵🔵🔵 [BLE_PERIPHERAL] Connection state event received: $state');
              Logger.info('🔵🔵🔵 Connection state event received in BlePeripheralService: $state');
              if (state is Map) {
                print('🔵 [BLE_PERIPHERAL] Adding to connection state controller');
                Logger.info('🔵 Adding to connection state controller');
                _connectionStateController.add(Map<String, dynamic>.from(state));
              } else {
                Logger.warning('🔵 Connection state event is not a Map: ${state.runtimeType}');
              }
            },
            onError: (error) {
              Logger.error('❌ Error in connection state stream', error);
            },
            onDone: () {
              Logger.warning('🔵 Connection state stream closed');
            },
            cancelOnError: false, // Don't cancel on error
          );
          print('✅ [BLE_PERIPHERAL] Connection state EventChannel listener set up successfully');
          Logger.info('✅ Connection state EventChannel listener set up successfully');
        } catch (e) {
          Logger.error('❌ Failed to set up connection state listener: $e');
          // Retry after a short delay
          Future.delayed(const Duration(milliseconds: 100), () {
            try {
              Logger.info('🔄 Retrying connection state listener setup...');
              _connectionStateSubscription = _connectionStateChannel.receiveBroadcastStream().listen(
                (state) {
                  Logger.info('🔵🔵🔵 Connection state event received (retry): $state');
                  if (state is Map) {
                    _connectionStateController.add(Map<String, dynamic>.from(state));
                  }
                },
                onError: (error) {
                  Logger.error('❌ Error in connection state stream (retry)', error);
                },
              );
              Logger.info('✅ Connection state listener set up on retry');
            } catch (e2) {
              Logger.error('❌ Failed to set up connection state listener on retry: $e2');
            }
          });
        }
        
        Logger.info('✅ BLE peripheral service initialized with connection state listener');
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

  /// @deprecated BLE is the Control Plane (discovery only) in the
  /// Dual-Radio Architecture. Chat messages MUST be sent via Wi-Fi Direct
  /// through [WifiDirectService] → [TransportManager].
  ///
  /// This method is intentionally disabled. Calling it will log an error
  /// and return false. Do NOT route chat payload over BLE.
  @Deprecated(
    'BLE is discovery-only. Use WifiDirectService.sendMessage() instead. '
    'Chat data must not travel over the BLE GATT channel.',
  )
  Future<bool> sendMessage(String message) async {
    Logger.error(
      'BlePeripheralService.sendMessage() called — '
      'BLE does NOT carry chat payload in the Dual-Radio Architecture. '
      'Route messages through WifiDirectService → TransportManager.',
    );
    // Do NOT forward to native — the GATT channel is discovery-only.
    return false;
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
    _connectionStateSubscription?.cancel();
    _messageController.close();
    _scanResultController.close();
    _connectionStateController.close();
  }
}