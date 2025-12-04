import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/message_model.dart';
import '../services/storage/message_storage.dart';
import '../providers/connection_provider.dart';
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
  final String _myDeviceId; // Our own device ID (for sending messages)
  final String _otherDeviceId; // The device we're chatting with
  StreamSubscription<String>? _messageSubscription;

  ChatNotifier(ConnectionNotifier connectionNotifier, String myDeviceId, String otherDeviceId)
      : _connectionNotifier = connectionNotifier,
        _myDeviceId = myDeviceId,
        _otherDeviceId = otherDeviceId,
        super(ChatState(currentDeviceId: otherDeviceId)) {
    _loadMessages();
    _setupMessageListener();
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

  Future<void> sendMessage(String content, String receiverId) async {
    if (content.trim().isEmpty) return;

    try {
      final message = MessageModel(
        id: const Uuid().v4(),
        content: content.trim(),
        senderId: _myDeviceId, // Our own device ID
        receiverId: receiverId, // The device we're sending to
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
        // The receiverId should be our device ID (the one receiving)
        message = message.copyWith(
          receiverId: _myDeviceId, // Our device ID (we're receiving)
          isSent: false,
          status: MessageStatus.delivered,
        );
        Logger.info('Parsed message from JSON: ${message.content} from ${message.senderId}');
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
      // Message is for this conversation if:
      // 1. The sender is the device we're chatting with (they sent it to us)
      // 2. OR the receiver is the device we're chatting with (we sent it to them)
      final isForThisConversation = message.senderId == _otherDeviceId || 
                                     message.receiverId == _otherDeviceId;
      
      if (!isForThisConversation) {
        Logger.debug('Message not for this conversation. Sender: ${message.senderId}, Receiver: ${message.receiverId}, Chatting with: $_otherDeviceId');
        // Still save it to storage, but don't add to current state
        MessageStorage.saveMessage(message);
        return;
      }

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

// Provider for current device ID (should be generated once per app install)
final currentDeviceIdProvider = Provider<String>((ref) {
  // In a real app, this would be stored and retrieved from local storage
  return const Uuid().v4();
});

// Provider for ChatNotifier
// The parameter is the device we're chatting with (otherDeviceId)
final chatProvider = StateNotifierProvider.family<ChatNotifier, ChatState, String>((ref, otherDeviceId) {
  final connectionNotifier = ref.watch(connectionProvider.notifier);
  final myDeviceId = ref.watch(currentDeviceIdProvider);
  return ChatNotifier(connectionNotifier, myDeviceId, otherDeviceId);
});

