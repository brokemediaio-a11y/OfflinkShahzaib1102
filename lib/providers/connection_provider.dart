import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/device_model.dart';
import '../services/communication/connection_manager.dart';
import '../utils/logger.dart';
import 'conversations_provider.dart';
import 'chat_provider.dart';
import '../models/message_model.dart';
import '../services/storage/message_storage.dart';
import '../services/storage/device_storage.dart';
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
      Logger.info('ConnectionProvider: global message handler received message');

      final jsonMap = _parseJsonString(messageJson);
      if (jsonMap == null) {
        Logger.warning('ConnectionProvider: could not parse message JSON');
        return;
      }

      var message = MessageModel.fromJson(jsonMap);
      message = message.copyWith(
        isSent: false,
        status: MessageStatus.delivered,
      );

      // Save to storage first so it is persisted regardless of UI state.
      MessageStorage.saveMessage(message);

      // ── Conversation key: the OTHER party's UUID ─────────────────
      // For an inbound message (isSent == false):
      //   • senderId / originalSenderId is the peer's UUID.
      // We use originalSenderId with a fallback to senderId — both are UUID.
      final peerUuid = message.originalSenderId.isNotEmpty
          ? message.originalSenderId
          : message.senderId;

      Logger.info(
          'ConnectionProvider: incoming message from peerUuid=$peerUuid, '
          'content="${message.content}"');

      // ── Peer display name resolution (UUID-only, no MAC) ─────────
      String deviceName;
      final storedName = DeviceStorage.getDeviceDisplayName(peerUuid);
      if (storedName != null && storedName.isNotEmpty) {
        deviceName = storedName;
      } else if (state.connectedDevice != null &&
          state.connectedDevice!.id == peerUuid &&
          state.connectedDevice!.name.isNotEmpty &&
          state.connectedDevice!.name != 'Unknown Device' &&
          state.connectedDevice!.name != peerUuid) {
        deviceName = state.connectedDevice!.name;
        // Cache the resolved name for future lookups.
        unawaited(DeviceStorage.setDeviceDisplayName(peerUuid, deviceName));
      } else {
        deviceName = peerUuid; // Fallback: show UUID until name is known
      }

      // ── Update conversations list ─────────────────────────────────
      _ref.read(conversationsProvider.notifier).updateConversation(message, deviceName);

      // ── Deliver to the open chat screen (if any) ─────────────────
      // chatProvider is keyed by peerUuid.  If the chat screen for this
      // peer is mounted, the provider exists and will show the message.
      // If not, the message is already persisted and will load on open.
      try {
        final chatNotifier = _ref.read(chatProvider(peerUuid).notifier);
        chatNotifier.receiveMessage(messageJson);
        Logger.info(
            'ConnectionProvider: delivered message to chatProvider($peerUuid)');
      } catch (e) {
        Logger.debug(
            'ConnectionProvider: chatProvider($peerUuid) not active — '
            'message persisted for later load');
      }

      Logger.info(
          'ConnectionProvider: message processed — peerUuid=$peerUuid, '
          'content="${message.content}"');
    } catch (e, stackTrace) {
      Logger.error('ConnectionProvider: error in global message handler', e, stackTrace);
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
      // Emit "connecting" immediately so the UI shows a spinner.
      // We must NOT emit "connected" here — that transition is driven
      // exclusively by the Wi-Fi Direct state stream in _setupListeners()
      // once the native layer confirms SOCKET_CONNECTED.
      state = state.copyWith(
        state: ConnectionStateType.connecting,
        error: null,
      );

      final started = await _connectionManager.connectToDevice(device);

      if (started) {
        // Connection attempt was accepted by the native layer.
        // Stay in "connecting" state — _setupListeners will emit "connected"
        // only when the TCP socket is actually established (socketActive == true).
        Logger.info(
            'Wi-Fi Direct negotiation started for ${device.name} — '
            'awaiting SOCKET_CONNECTED event…');
      } else {
        state = state.copyWith(
          state: ConnectionStateType.error,
          error: 'Failed to start Wi-Fi Direct connection',
        );
      }

      return started;
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

// Provider for ConnectionManager singleton
final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  return ConnectionManager();
});

// Provider for ConnectionNotifier
final connectionProvider = StateNotifierProvider<ConnectionNotifier, ConnectionProviderState>((ref) {
  final connectionManager = ref.watch(connectionManagerProvider);
  return ConnectionNotifier(connectionManager, ref);
});

