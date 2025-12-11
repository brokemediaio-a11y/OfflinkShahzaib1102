import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/device_model.dart';
import '../services/communication/connection_manager.dart';
import '../utils/logger.dart';
import 'device_provider.dart';
import 'conversations_provider.dart';
import 'chat_provider.dart';
import '../models/message_model.dart';
import '../services/storage/message_storage.dart';
import 'dart:convert';

class ConnectionProviderState {
  final ConnectionStateType state;
  final DeviceModel? connectedDevice;
  final ConnectionType connectionType;
  final String? error;

  ConnectionProviderState({
    this.state = ConnectionStateType.disconnected,
    this.connectedDevice,
    this.connectionType = ConnectionType.none,
    this.error,
  });

  ConnectionProviderState copyWith({
    ConnectionStateType? state,
    DeviceModel? connectedDevice,
    ConnectionType? connectionType,
    String? error,
  }) {
    return ConnectionProviderState(
      state: state ?? this.state,
      connectedDevice: connectedDevice ?? this.connectedDevice,
      connectionType: connectionType ?? this.connectionType,
      error: error ?? this.error,
    );
  }
}

enum ConnectionStateType {
  disconnected,
  connecting,
  connected,
  error,
}

class ConnectionNotifier extends StateNotifier<ConnectionProviderState> {
  final ConnectionManager _connectionManager;
  final Ref _ref; // Add this to access other providers
  StreamSubscription<ConnectionState>? _connectionSubscription;
  StreamSubscription<String>? _messageSubscription;

  ConnectionNotifier(this._connectionManager, this._ref) : super(ConnectionProviderState()) {
    _setupListeners();
  }

  void _setupListeners() {
    _connectionSubscription = _connectionManager.connectionState.listen(
      (connectionState) {
        switch (connectionState) {
          case ConnectionState.connected:
            state = state.copyWith(
              state: ConnectionStateType.connected,
              connectedDevice: _connectionManager.connectedDevice,
              connectionType: _connectionManager.currentConnectionType,
              error: null,
            );
            break;
          case ConnectionState.disconnected:
            state = state.copyWith(
              state: ConnectionStateType.disconnected,
              connectedDevice: null,
              connectionType: ConnectionType.none,
              error: null,
            );
            break;
          case ConnectionState.connecting:
            state = state.copyWith(
              state: ConnectionStateType.connecting,
              error: null,
            );
            break;
          case ConnectionState.error:
            state = state.copyWith(
              state: ConnectionStateType.error,
              error: 'Connection error occurred',
            );
            break;
        }
      },
    );

    // GLOBAL MESSAGE LISTENER - persists across screens
    _messageSubscription = _connectionManager.incomingMessages.listen(
      (messageJson) {
        _handleIncomingMessageGlobally(messageJson);
      },
    );
  }

  void _handleIncomingMessageGlobally(String messageJson) {
    try {
      Logger.info('Global message handler received: $messageJson');
      
      // Parse the message
      final jsonMap = _parseJsonString(messageJson);
      if (jsonMap == null) {
        Logger.warning('Could not parse message JSON');
        return;
      }

      var message = MessageModel.fromJson(jsonMap);
      message = message.copyWith(
        isSent: false,
        status: MessageStatus.delivered,
      );

      // Save to storage
      MessageStorage.saveMessage(message);

      // Determine device name (use senderId or get from connected device)
      String deviceName = message.senderId;
      if (state.connectedDevice != null && 
          (state.connectedDevice!.id == message.senderId || 
           state.connectedDevice!.id == message.receiverId)) {
        deviceName = state.connectedDevice!.name;
      }

      // Update conversations list
      _ref.read(conversationsProvider.notifier).updateConversation(message, deviceName);

      // Try to notify the chat provider for this device if it exists
      // The chat provider is a family provider, so we need the device ID
      final senderId = message.senderId;
      try {
        // Try to access the chat provider for the sender device
        // If the chat screen is open for this device, the provider will exist
        final chatNotifier = _ref.read(chatProvider(senderId).notifier);
        // Call receiveMessage with the original JSON
        chatNotifier.receiveMessage(messageJson);
        Logger.info('Notified chat provider for device: $senderId');
      } catch (e) {
        // Chat provider doesn't exist for this device (chat screen not open)
        // This is fine - messages are saved and will load when chat opens
        Logger.debug('Chat provider not active for device: $senderId');
      }
      
      Logger.info('Message processed globally: ${message.content}');
    } catch (e, stackTrace) {
      Logger.error('Error in global message handler', e, stackTrace);
    }
  }

  Map<String, dynamic>? _parseJsonString(String jsonString) {
    try {
      final cleaned = jsonString.trim();
      String jsonToParse = cleaned;
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        jsonToParse = cleaned.substring(1, cleaned.length - 1);
        jsonToParse = jsonToParse.replaceAll('\\"', '"').replaceAll('\\n', '\n');
      }
      return jsonDecode(jsonToParse) as Map<String, dynamic>;
    } catch (e) {
      Logger.error('Error parsing JSON string', e);
      return null;
    }
  }

  Future<bool> connectToDevice(DeviceModel device) async {
    try {
      state = state.copyWith(
        state: ConnectionStateType.connecting,
        error: null,
      );

      final connected = await _connectionManager.connectToDevice(device);

      if (connected) {
        state = state.copyWith(
          state: ConnectionStateType.connected,
          connectedDevice: _connectionManager.connectedDevice,
          connectionType: _connectionManager.currentConnectionType,
          error: null,
        );
        Logger.info('Connected to device: ${device.name}');
      } else {
        state = state.copyWith(
          state: ConnectionStateType.error,
          error: 'Failed to connect to device',
        );
      }

      return connected;
    } catch (e) {
      state = state.copyWith(
        state: ConnectionStateType.error,
        error: 'Connection error: ${e.toString()}',
      );
      Logger.error('Error connecting to device', e);
      return false;
    }
  }

  Future<void> disconnect() async {
    try {
      await _connectionManager.disconnect();
      state = state.copyWith(
        state: ConnectionStateType.disconnected,
        connectedDevice: null,
        connectionType: ConnectionType.none,
        error: null,
      );
      Logger.info('Disconnected from device');
    } catch (e) {
      state = state.copyWith(
        state: ConnectionStateType.error,
        error: 'Disconnect error: ${e.toString()}',
      );
      Logger.error('Error disconnecting', e);
    }
  }

  Future<bool> sendMessage(String message) async {
    try {
      // Check if connected before sending
      if (state.state != ConnectionStateType.connected) {
        Logger.warning('Cannot send message: not connected to any device');
        return false;
      }
      return await _connectionManager.sendMessage(message);
    } catch (e) {
      Logger.error('Error sending message', e);
      return false;
    }
  }

  bool isConnected() {
    return _connectionManager.isConnected();
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _messageSubscription?.cancel();
    super.dispose();
  }
}

// Provider for ConnectionNotifier
final connectionProvider = StateNotifierProvider<ConnectionNotifier, ConnectionProviderState>((ref) {
  final connectionManager = ref.watch(connectionManagerProvider);
  return ConnectionNotifier(connectionManager, ref);
});

