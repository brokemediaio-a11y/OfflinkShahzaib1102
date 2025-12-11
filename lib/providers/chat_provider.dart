import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/message_model.dart';
import '../models/device_model.dart';
import '../services/storage/message_storage.dart';
import '../services/storage/device_storage.dart';
import '../providers/connection_provider.dart';
import '../providers/device_provider.dart';
import 'conversations_provider.dart';
import '../utils/logger.dart';

class ChatState {
  final List<MessageModel> messages;
  final bool isSending;
  final String? error;
  final String currentDeviceId;

  ChatState({
    this.messages = const [],
    this.isSending = false,
    this.error,
    required this.currentDeviceId,
  });

  ChatState copyWith({
    List<MessageModel>? messages,
    bool? isSending,
    String? error,
    String? currentDeviceId,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isSending: isSending ?? this.isSending,
      error: error ?? this.error,
      currentDeviceId: currentDeviceId ?? this.currentDeviceId,
    );
  }
}

class ChatNotifier extends StateNotifier<ChatState> {
  final ConnectionNotifier _connectionNotifier;
  final Ref _ref; // Add ref to access other providers
  final String _myDeviceId; // Our own device ID (for sending messages)
  final String _otherDeviceId; // The device we're chatting with
  DeviceModel? _otherDevice; // Store device info for auto-connection
  StreamSubscription<String>? _messageSubscription;

  ChatNotifier(ConnectionNotifier connectionNotifier, Ref ref, String myDeviceId, String otherDeviceId)
      : _connectionNotifier = connectionNotifier,
        _ref = ref,
        _myDeviceId = myDeviceId,
        _otherDeviceId = otherDeviceId,
        super(ChatState(currentDeviceId: otherDeviceId)) {
    _loadMessages();
    _setupMessageListener();
    Logger.info('ChatNotifier initialized: myDeviceId=$myDeviceId, otherDeviceId=$otherDeviceId');
  }

  // Set device info (called from chat screen)
  void setDeviceInfo(DeviceModel device) {
    _otherDevice = device;
    // IMPORTANT: Update _otherDeviceId to match the device's ID
    // This ensures we use the correct device ID (UUID from conversation) when sending messages
    // Note: _otherDeviceId is final, so we can't change it directly
    // But the chat provider is created with the correct otherDeviceId from the conversation
    Logger.info('Device info set: id=${device.id}, address=${device.address}, _otherDeviceId=$_otherDeviceId');
  }

  void _setupMessageListener() {
    // Listen to incoming messages from connection manager
    // Note: This would need to be set up through the connection manager
    // For now, we'll handle messages when they arrive
  }

  Future<void> _loadMessages() async {
    try {
      // Load messages for the conversation with the other device
      final messages = MessageStorage.getMessagesForConversation(_otherDeviceId);
      // Sort messages by timestamp
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      state = state.copyWith(messages: messages);
      Logger.info('Loaded ${messages.length} messages for conversation with: $_otherDeviceId');
    } catch (e) {
      Logger.error('Error loading messages', e);
      state = state.copyWith(error: 'Failed to load messages');
    }
  }

  Future<void> sendMessage(String content, String receiverId, {DeviceModel? device}) async {
    if (content.trim().isEmpty) return;

    try {
      // IMPORTANT: Use _otherDeviceId as the receiverId to ensure consistency
      // This ensures Device 2 replies to the same UUID it received the message from
      // _otherDeviceId is set when the chat screen is opened and contains the senderId from the received message
      String finalReceiverId = _otherDeviceId.isNotEmpty ? _otherDeviceId : receiverId;
      
      Logger.info('Sending message: receiverId=$finalReceiverId, _otherDeviceId=$_otherDeviceId, provided receiverId=$receiverId');
      
      // Check if we're connected to the target device
      // IMPORTANT: If we're already connected, assume it's the right device
      // The connection was established when opening the chat, so we should trust it
      final connectionState = _ref.read(connectionProvider);
      final isConnected = connectionState.state == ConnectionStateType.connected;
      
      // If connected, check if it's the right device
      // Handle UUID vs MAC address matching - but be lenient if already connected
      bool isCorrectDevice = false;
      if (isConnected && connectionState.connectedDevice != null) {
        final connectedDevice = connectionState.connectedDevice!;
        // Match by ID or address (handles UUID vs MAC)
        isCorrectDevice = connectedDevice.id == finalReceiverId ||
                         connectedDevice.address == finalReceiverId ||
                         connectedDevice.id == receiverId ||
                         connectedDevice.address == receiverId ||
                         // Also check if _otherDevice matches
                         (_otherDevice != null && (
                           connectedDevice.id == _otherDevice!.id ||
                           connectedDevice.address == _otherDevice!.address ||
                           connectedDevice.id == _otherDevice!.address ||
                           connectedDevice.address == _otherDevice!.id
                         ));
        
        // IMPORTANT: If we're connected but device IDs don't match exactly,
        // still assume it's correct if we're in a chat screen (user already connected)
        // This prevents unnecessary disconnection and reconnection
        if (!isCorrectDevice && _otherDevice != null) {
          // Check if the connected device's MAC matches _otherDevice's address
          // or if they're both "Offlink" devices (likely the same device)
          if (connectedDevice.name.toLowerCase().contains('offlink') &&
              _otherDevice!.name.toLowerCase().contains('offlink')) {
            isCorrectDevice = true;
            Logger.info('Assuming correct device based on name match (both Offlink)');
          }
        }
        
        Logger.info('Connection check: isConnected=$isConnected, isCorrectDevice=$isCorrectDevice');
        Logger.info('  connectedDevice: id=${connectedDevice.id}, address=${connectedDevice.address}, name=${connectedDevice.name}');
        Logger.info('  finalReceiverId: $finalReceiverId, receiverId: $receiverId');
        Logger.info('  _otherDevice: id=${_otherDevice?.id}, address=${_otherDevice?.address}, name=${_otherDevice?.name}');
      }
      
      // Only try to connect if not connected
      // IMPORTANT: If already connected, assume it's the correct device
      // Don't disconnect and reconnect just because IDs don't match exactly
      // The user already connected when opening the chat, so trust that connection
      final shouldConnect = !isConnected;
      
      if (isConnected && !isCorrectDevice) {
        Logger.warning('Connected but device IDs don\'t match exactly. Assuming correct device since user already connected.');
        Logger.warning('  This is normal when UUID (conversation) vs MAC (BLE connection) formats differ.');
      }

      // If not connected or connected to wrong device, try to auto-connect by scanning
      if (shouldConnect) {
        Logger.info('Not connected to device. Scanning and attempting auto-connection...');
        state = state.copyWith(
          isSending: true,
          error: 'Connecting to device...',
        );

        final deviceNotifier = _ref.read(deviceProvider.notifier);
        
        // Always scan to find the device (device info might have UUID instead of MAC)
        Logger.info('Starting scan to find device...');
        await deviceNotifier.startScan();
        
        // Wait for devices to be discovered (increase wait time)
        await Future.delayed(const Duration(seconds: 5));
        
        // Get discovered devices
        final discoveredDevices = _ref.read(deviceProvider).discoveredDevices;
        Logger.info('Found ${discoveredDevices.length} devices during scan');
        
        // Find the target device - try multiple matching strategies
        DeviceModel? foundDevice;
        for (final d in discoveredDevices) {
          Logger.debug('Checking device: id=${d.id}, address=${d.address}, name=${d.name}');
          
          // Match by receiverId (could be UUID or MAC)
          if (d.id == receiverId || d.address == receiverId) {
            foundDevice = d;
            Logger.info('Matched device by receiverId: ${d.name}');
            break;
          }
          
          // If we have device info, try matching by id or address
          final targetDevice = device ?? _otherDevice;
          if (targetDevice != null) {
            // Match by target device id or address
            if (d.id == targetDevice.id || d.address == targetDevice.address) {
              foundDevice = d;
              Logger.info('Matched device by target device info: ${d.name}');
              break;
            }
            // If target device has UUID as address, try matching by discovered device's id
            if (!targetDevice.address.contains(':') && d.id == targetDevice.address) {
              foundDevice = d;
              Logger.info('Matched device by UUID: ${d.name}');
              break;
            }
          }
          
          // If receiverId looks like MAC address, match by address
          if (receiverId.contains(':') && receiverId.length == 17 && d.address == receiverId) {
            foundDevice = d;
            Logger.info('Matched device by MAC address: ${d.name}');
            break;
          }
        }
        
        // Stop scan
        await deviceNotifier.stopScan();
        
        if (foundDevice != null) {
          Logger.info('Found device: ${foundDevice.name} (${foundDevice.address}). Connecting...');
          final connected = await _connectionNotifier.connectToDevice(foundDevice);
          if (!connected) {
            state = state.copyWith(
              isSending: false,
              error: 'Failed to connect to device. Please ensure device is nearby and try again.',
            );
            Logger.error('Failed to auto-connect to device: ${foundDevice.name}');
            return;
          }
          // Update stored device info with actual discovered device
          _otherDevice = foundDevice;
          // IMPORTANT: Keep using _otherDeviceId (the UUID from the received message)
          // Don't change finalReceiverId to foundDevice.id - we want to reply to the same UUID we received from
          // This ensures Device 2 replies to Device 1's UUID, not Device 1's MAC address
          Logger.info('Successfully connected to device: ${foundDevice.name}. Will reply to: $finalReceiverId');
        } else {
          state = state.copyWith(
            isSending: false,
            error: 'Device not found. Please ensure device is nearby and advertising, then try again.',
          );
          Logger.error('Target device not found during scan. ReceiverId: $finalReceiverId');
          return;
        }
      } else {
        // We're already connected - but still use _otherDeviceId to ensure we reply to the correct UUID
        // Don't change finalReceiverId - it's already set to _otherDeviceId at the start
        Logger.info('Already connected. Will reply to: $finalReceiverId');
      }

      final message = MessageModel(
        id: const Uuid().v4(),
        content: content.trim(),
        senderId: _myDeviceId, // Our own device ID
        receiverId: finalReceiverId, // The device we're sending to (now using connected device's ID)
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
        isSent: true,
      );

      // Add message to state immediately
      state = state.copyWith(
        messages: [...state.messages, message],
        isSending: true,
        error: null,
      );

      // Save to local storage
      await MessageStorage.saveMessage(message);

      // Update conversations list
      try {
        _ref.read(conversationsProvider.notifier).updateConversation(message, _otherDeviceId);
      } catch (e) {
        Logger.error('Error updating conversations', e);
      }

      // Send via connection manager
      // Convert message to JSON string properly using jsonEncode
      final messageJson = jsonEncode(message.toJson());
      final sent = await _connectionNotifier.sendMessage(messageJson);

      if (sent) {
        // Update message status to sent
        await MessageStorage.updateMessageStatus(
          message.id,
          MessageStatus.sent,
        );
        
        final updatedMessages = state.messages.map((m) {
          if (m.id == message.id) {
            return m.copyWith(status: MessageStatus.sent);
          }
          return m;
        }).toList();

        state = state.copyWith(
          messages: updatedMessages,
          isSending: false,
        );
        Logger.info('Message sent successfully');
      } else {
        // Update message status to failed
        await MessageStorage.updateMessageStatus(
          message.id,
          MessageStatus.failed,
        );
        
        final updatedMessages = state.messages.map((m) {
          if (m.id == message.id) {
            return m.copyWith(status: MessageStatus.failed);
          }
          return m;
        }).toList();

        state = state.copyWith(
          messages: updatedMessages,
          isSending: false,
          error: 'Failed to send message',
        );
        Logger.error('Failed to send message');
      }
    } catch (e) {
      Logger.error('Error sending message', e);
      state = state.copyWith(
        isSending: false,
        error: 'Error sending message: ${e.toString()}',
      );
    }
  }

  void receiveMessage(String messageJson) {
    try {
      Logger.info('Received message JSON: $messageJson');
      
      // Parse the JSON string to extract the message data
      final jsonMap = _parseJsonString(messageJson);
      
      MessageModel message;
      
      if (jsonMap != null) {
        // Parse from JSON
        message = MessageModel.fromJson(jsonMap);
        // Mark as received (not sent by this device)
        // Keep the original receiverId (it's our MAC address when we receive)
        message = message.copyWith(
          isSent: false,
          status: MessageStatus.delivered,
        );
        Logger.info('Parsed message from JSON: ${message.content} from ${message.senderId} to ${message.receiverId}');
      } else {
        // Fallback: treat as plain text message
        Logger.warning('Could not parse message JSON, treating as plain text: $messageJson');
        message = MessageModel(
          id: const Uuid().v4(),
          content: messageJson,
          senderId: _otherDeviceId, // Assume it's from the device we're chatting with
          receiverId: _myDeviceId, // We're receiving it
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
          isSent: false,
        );
      }

      // Check if message already exists (avoid duplicates)
      final exists = state.messages.any((m) => m.id == message.id);
      if (exists) {
        Logger.debug('Message already exists, skipping: ${message.id}');
        return;
      }

      // Check if message is for this conversation
      // When receiving a message:
      // - receiverId: Our MAC address (we're receiving it) - e.g., "58:8B:3F:38:CE:9D" (TECNO's MAC)
      // - senderId: UUID or MAC of the sender - e.g., "731746e5-ddd3-4fe3-9ad1-870903140f63" (UUID from OPPO)
      // - _otherDeviceId: MAC address of the device we're chatting with - e.g., "40:93:EF:97:B5:0D" (OPPO's MAC)
      // - _myDeviceId: Our device UUID (not MAC)
      
      // Match messages by:
      // 1. If receiverId matches the other device (we sent it to them) - receiverId = _otherDeviceId
      // 2. If we're receiving (receiverId is a MAC address in format XX:XX:XX:XX:XX:XX), accept it
      //    since we're in a 1-on-1 chat screen - this means it's addressed to us
      // 3. If senderId matches the other device (they sent it to us) - senderId = _otherDeviceId
      
      final receiverMatchesOtherDevice = message.receiverId == _otherDeviceId;
      final senderMatchesOtherDevice = message.senderId == _otherDeviceId;
      
      // Check if receiverId is a MAC address (format: XX:XX:XX:XX:XX:XX, 17 chars)
      // If we're receiving a message with a MAC address as receiverId, it's addressed to us
      // Since we're in a chat screen, accept all received messages (receiverId is MAC = we're receiving)
      final receiverIdIsMacAddress = message.receiverId.contains(':') && 
                                      message.receiverId.length == 17;
      
      // Accept message if:
      // 1. Receiver matches other device (we sent it to them)
      // 2. OR sender matches other device (they sent it to us)
      // 3. OR we're receiving (receiverId is MAC address) - accept since we're in a 1-on-1 chat screen
      final isForThisConversation = receiverMatchesOtherDevice || 
                                     senderMatchesOtherDevice ||
                                     (receiverIdIsMacAddress && !message.isSent);
      
      Logger.info('Message matching check: receiverId=${message.receiverId}, senderId=${message.senderId}, _otherDeviceId=$_otherDeviceId, isSent=${message.isSent}');
      Logger.info('  - receiverMatchesOtherDevice: $receiverMatchesOtherDevice');
      Logger.info('  - senderMatchesOtherDevice: $senderMatchesOtherDevice');
      Logger.info('  - receiverIdIsMacAddress: $receiverIdIsMacAddress');
      Logger.info('  - isForThisConversation: $isForThisConversation');
      
      if (!isForThisConversation) {
        Logger.info('Message not for this conversation. Sender: ${message.senderId}, Receiver: ${message.receiverId}, Chatting with: $_otherDeviceId, isSent: ${message.isSent}');
        Logger.info('Message content: ${message.content}');
        // Still save it to storage, but don't add to current state
        MessageStorage.saveMessage(message);
        return;
      }
      
      Logger.info('Message accepted for conversation. Content: ${message.content}');

      // Add to state
      final updatedMessages = [...state.messages, message];
      // Sort by timestamp
      updatedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      
      state = state.copyWith(
        messages: updatedMessages,
      );

      // Save to local storage
      MessageStorage.saveMessage(message);
      Logger.info('Message received and saved: ${message.content}');
    } catch (e, stackTrace) {
      Logger.error('Error receiving message', e, stackTrace);
      // Try to save as plain text message as fallback
      try {
        final fallbackMessage = MessageModel(
          id: const Uuid().v4(),
          content: messageJson,
          senderId: _otherDeviceId, // Assume from device we're chatting with
          receiverId: _myDeviceId, // We're receiving it
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
          isSent: false,
        );
        final updatedMessages = [...state.messages, fallbackMessage];
        updatedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        state = state.copyWith(
          messages: updatedMessages,
        );
        MessageStorage.saveMessage(fallbackMessage);
      } catch (e2) {
        Logger.error('Error saving fallback message', e2);
      }
    }
  }

  Map<String, dynamic>? _parseJsonString(String jsonString) {
    try {
      // Remove any leading/trailing whitespace
      final cleaned = jsonString.trim();
      
      // Handle case where JSON might be wrapped in quotes or have extra characters
      String jsonToParse = cleaned;
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        // Remove surrounding quotes
        jsonToParse = cleaned.substring(1, cleaned.length - 1);
        // Unescape JSON string
        jsonToParse = jsonToParse.replaceAll('\\"', '"').replaceAll('\\n', '\n');
      }
      
      // Parse JSON string to Map
      final decoded = jsonDecode(jsonToParse) as Map<String, dynamic>;
      return decoded;
    } catch (e) {
      Logger.error('Error parsing JSON string: $jsonString', e);
      return null;
    }
  }

  Future<void> loadMessagesForConversation(String otherDeviceId) async {
    try {
      // Get messages where the other device is involved
      // This includes messages we sent to them AND messages they sent to us
      final messages = MessageStorage.getMessagesForConversation(_otherDeviceId);
      // Sort messages by timestamp
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      state = state.copyWith(messages: messages);
      Logger.info('Loaded ${messages.length} messages for conversation with: $_otherDeviceId');
    } catch (e) {
      Logger.error('Error loading conversation messages', e);
      state = state.copyWith(error: 'Failed to load messages');
    }
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }
}

// Provider for current device ID (persistent across app restarts)
final currentDeviceIdProvider = Provider<String>((ref) {
  return DeviceStorage.getDeviceId();
});

// Provider for ChatNotifier
// The parameter is the device we're chatting with (otherDeviceId)
final chatProvider = StateNotifierProvider.family<ChatNotifier, ChatState, String>((ref, otherDeviceId) {
  final connectionNotifier = ref.watch(connectionProvider.notifier);
  final myDeviceId = ref.watch(currentDeviceIdProvider);
  return ChatNotifier(connectionNotifier, ref, myDeviceId, otherDeviceId);
});

