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
      
      // Check if we're connected to any device
      // IMPORTANT: If we're already connected (as central OR peripheral), use that connection
      // This allows replies to work even when we're in peripheral mode (central connected to us)
      final connectionState = _ref.read(connectionProvider);
      final isConnected = connectionState.state == ConnectionStateType.connected;
      
      Logger.info('Connection check: isConnected=$isConnected');
      if (isConnected && connectionState.connectedDevice != null) {
        Logger.info('  connectedDevice: id=${connectionState.connectedDevice!.id}, address=${connectionState.connectedDevice!.address}, name=${connectionState.connectedDevice!.name}');
        Logger.info('  finalReceiverId: $finalReceiverId, receiverId: $receiverId');
      }

      // If already connected, skip scanning and just send the message
      // This works for both central and peripheral connections
      if (isConnected) {
        Logger.info('Already connected (central or peripheral). Will send message to: $finalReceiverId');
        // Continue to message sending logic below
      } else {
        // Not connected - try to auto-connect by scanning
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
        
        // Find the target device by UUID only
        // receiverId should always be a UUID now
        DeviceModel? foundDevice;
        for (final d in discoveredDevices) {
          Logger.debug('Checking device: id=${d.id} (UUID), address=${d.address} (MAC), name=${d.name}');
          
          // Match by UUID (receiverId should be UUID)
          if (d.id == receiverId) {
            foundDevice = d;
            Logger.info('Matched device by UUID: ${d.name}');
            break;
          }
          
          // If we have device info, try matching by UUID
          final targetDevice = device ?? _otherDevice;
          if (targetDevice != null && d.id == targetDevice.id) {
            foundDevice = d;
            Logger.info('Matched device by target device UUID: ${d.name}');
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
      }

      // NEW: Create message with routing fields for mesh networking
      final messageId = const Uuid().v4();
      final message = MessageModel(
        id: messageId, // Legacy field for backward compatibility
        content: content.trim(),
        senderId: _myDeviceId, // Legacy field for backward compatibility
        receiverId: finalReceiverId, // Legacy field for backward compatibility
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
        isSent: true,
        // NEW: Routing fields for mesh networking
        messageId: messageId, // Unique message identifier for deduplication
        originalSenderId: _myDeviceId, // Device that created the message
        finalReceiverId: finalReceiverId, // Intended destination device
        hopCount: 0, // Starting hop count
        maxHops: 3, // Maximum hops allowed (TTL)
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
        // Get stored name for the receiver, or use device name
        final storedName = DeviceStorage.getDeviceDisplayName(finalReceiverId);
        final deviceName = storedName ?? finalReceiverId;
        _ref.read(conversationsProvider.notifier).updateConversation(message, deviceName);
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

