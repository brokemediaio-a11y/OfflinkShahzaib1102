import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/message_model.dart';
import '../models/device_model.dart';
import '../services/storage/message_storage.dart';
import '../services/storage/device_storage.dart';
import '../services/storage/pending_message_storage.dart';
import '../providers/connection_provider.dart';
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
  final Ref _ref;
  final String _myDeviceId;
  final String _otherDeviceId;
  DeviceModel? _otherDevice;
  StreamSubscription<String>? _messageSubscription;

  ChatNotifier(ConnectionNotifier connectionNotifier, Ref ref,
      String myDeviceId, String otherDeviceId)
      : _connectionNotifier = connectionNotifier,
        _ref = ref,
        _myDeviceId = myDeviceId,
        _otherDeviceId = otherDeviceId,
        super(ChatState(currentDeviceId: otherDeviceId)) {
    _loadMessages();
    Logger.info(
        'ChatNotifier initialized: myDeviceId=$myDeviceId, otherDeviceId=$otherDeviceId');
  }

  void setDeviceInfo(DeviceModel device) {
    _otherDevice = device;
    Logger.info(
        'Device info set: id=${device.id}, address=${device.address}, '
        '_otherDeviceId=$_otherDeviceId');
  }

  Future<void> _loadMessages() async {
    try {
      final messages = MessageStorage.getMessagesForConversation(_otherDeviceId);
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      state = state.copyWith(messages: messages);
      Logger.info(
          'Loaded ${messages.length} messages for conversation with: $_otherDeviceId');
    } catch (e) {
      Logger.error('Error loading messages', e);
      state = state.copyWith(error: 'Failed to load messages');
    }
  }

  // ─────────────────────────────────────────────────────────────────
  // Send — works online OR offline (store-and-forward)
  // ─────────────────────────────────────────────────────────────────

  Future<void> sendMessage(String content, String receiverId,
      {DeviceModel? device}) async {
    if (content.trim().isEmpty) return;

    try {
      final String finalReceiverId = _otherDeviceId;

      Logger.info(
          'ChatNotifier.sendMessage: receiverId=$finalReceiverId');

      // ── Build the message ─────────────────────────────────────────
      final messageId = const Uuid().v4();
      final message = MessageModel(
        id: messageId,
        content: content.trim(),
        senderId: _myDeviceId,
        receiverId: finalReceiverId,
        timestamp: DateTime.now(),
        status: MessageStatus.sending,
        isSent: true,
        messageId: messageId,
        originalSenderId: _myDeviceId,
        finalReceiverId: finalReceiverId,
        senderPeerId: _myDeviceId,
        hopCount: 0,
        maxHops: 5,
      );

      // ── Optimistic UI update ──────────────────────────────────────
      state = state.copyWith(
        messages: [...state.messages, message],
        isSending: true,
        error: null,
      );

      // ── Persist message ───────────────────────────────────────────
      await MessageStorage.saveMessage(message);

      // ── Update conversations list ─────────────────────────────────
      try {
        final storedName = DeviceStorage.getDeviceDisplayName(finalReceiverId);
        final deviceName = storedName ?? finalReceiverId;
        _ref
            .read(conversationsProvider.notifier)
            .updateConversation(message, deviceName);
      } catch (e) {
        Logger.error('Error updating conversations', e);
      }

      // ── Check connection ──────────────────────────────────────────
      final connectionState = _ref.read(connectionProvider);
      final isConnected =
          connectionState.state == ConnectionStateType.connected;

      if (isConnected) {
        // ── ONLINE: send directly ─────────────────────────────────
        final messageJson = jsonEncode(message.toJson());
        final sent = await _connectionNotifier.sendMessage(messageJson);

        if (sent) {
          await MessageStorage.updateMessageStatus(
              message.id, MessageStatus.sent);
          _updateMessageInState(message.id, MessageStatus.sent);
          Logger.info('ChatNotifier: ✅ message sent successfully');
        } else {
          // Send failed even though connected — queue as pending
          await _queueAsPending(message);
        }
      } else {
        // ── OFFLINE: queue for store-and-forward ─────────────────
        Logger.info(
            'ChatNotifier: peer offline — queuing message ${message.messageId} '
            'for store-and-forward delivery');
        await _queueAsPending(message);
      }
    } catch (e) {
      Logger.error('Error sending message', e);
      state = state.copyWith(
        isSending: false,
        error: 'Error sending message: ${e.toString()}',
      );
    }
  }

  /// Save message to the pending queue and update status to [MessageStatus.pending].
  Future<void> _queueAsPending(MessageModel message) async {
    final pendingMessage = message.copyWith(status: MessageStatus.pending);
    await PendingMessageStorage.savePendingMessage(pendingMessage);
    await MessageStorage.updateMessageStatus(message.id, MessageStatus.pending);
    _updateMessageInState(message.id, MessageStatus.pending);
    state = state.copyWith(isSending: false);
    Logger.info(
        'ChatNotifier: 📥 message ${message.messageId} queued as pending');
  }

  /// Update a single message's status in the current UI state.
  void _updateMessageInState(String messageId, MessageStatus status) {
    final updated = state.messages.map((m) {
      if (m.id == messageId) return m.copyWith(status: status);
      return m;
    }).toList();
    state = state.copyWith(messages: updated, isSending: false);
  }

  // ─────────────────────────────────────────────────────────────────
  // Called by ConnectionProvider when a delivery ACK arrives
  // ─────────────────────────────────────────────────────────────────

  void updateMessageDeliveryStatus(String messageId, MessageStatus status) {
    _updateMessageInState(messageId, status);
    Logger.info(
        'ChatNotifier: 📬 message $messageId status → ${status.name}');
  }

  // ─────────────────────────────────────────────────────────────────
  // Receive
  // ─────────────────────────────────────────────────────────────────

  void receiveMessage(String messageJson) {
    try {
      Logger.info('Received message JSON: $messageJson');

      final jsonMap = _parseJsonString(messageJson);

      MessageModel message;

      if (jsonMap != null) {
        message = MessageModel.fromJson(jsonMap);
        message = message.copyWith(
          isSent: false,
          status: MessageStatus.delivered,
        );
        Logger.info(
            'Parsed message from JSON: ${message.content} '
            'from ${message.senderId} to ${message.receiverId}');
      } else {
        Logger.warning(
            'Could not parse message JSON, treating as plain text: $messageJson');
        message = MessageModel(
          id: const Uuid().v4(),
          content: messageJson,
          senderId: _otherDeviceId,
          receiverId: _myDeviceId,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
          isSent: false,
        );
      }

      // Deduplication
      final exists = state.messages.any((m) => m.id == message.id);
      if (exists) {
        Logger.debug('Message already exists, skipping: ${message.id}');
        return;
      }

      // Conversation filter
      final senderMatchesOtherDevice = message.senderId == _otherDeviceId ||
          message.originalSenderId == _otherDeviceId;
      final receiverMatchesOtherDevice =
          message.receiverId == _otherDeviceId ||
              message.finalReceiverId == _otherDeviceId;
      final isForThisConversation =
          senderMatchesOtherDevice || receiverMatchesOtherDevice;

      Logger.info(
          'ChatNotifier.receiveMessage: '
          'senderId=${message.senderId}, receiverId=${message.receiverId}, '
          '_otherDeviceId=$_otherDeviceId → '
          'senderMatch=$senderMatchesOtherDevice, '
          'receiverMatch=$receiverMatchesOtherDevice');

      if (!isForThisConversation) {
        Logger.warning(
            'ChatNotifier: message not for this conversation — '
            'sender=${message.senderId}, receiver=${message.receiverId}, '
            'chatWith=$_otherDeviceId');
        MessageStorage.saveMessage(message);
        return;
      }

      Logger.info(
          'ChatNotifier: message accepted. Content: ${message.content}');

      final updatedMessages = [...state.messages, message];
      updatedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      state = state.copyWith(messages: updatedMessages);
      MessageStorage.saveMessage(message);
      Logger.info('Message received and saved: ${message.content}');
    } catch (e, stackTrace) {
      Logger.error('Error receiving message', e, stackTrace);
      try {
        final fallbackMessage = MessageModel(
          id: const Uuid().v4(),
          content: messageJson,
          senderId: _otherDeviceId,
          receiverId: _myDeviceId,
          timestamp: DateTime.now(),
          status: MessageStatus.delivered,
          isSent: false,
        );
        final updatedMessages = [...state.messages, fallbackMessage];
        updatedMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        state = state.copyWith(messages: updatedMessages);
        MessageStorage.saveMessage(fallbackMessage);
      } catch (e2) {
        Logger.error('Error saving fallback message', e2);
      }
    }
  }

  Map<String, dynamic>? _parseJsonString(String jsonString) {
    try {
      final cleaned = jsonString.trim();
      String jsonToParse = cleaned;
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        jsonToParse = cleaned.substring(1, cleaned.length - 1);
        jsonToParse =
            jsonToParse.replaceAll('\\"', '"').replaceAll('\\n', '\n');
      }
      return jsonDecode(jsonToParse) as Map<String, dynamic>;
    } catch (e) {
      Logger.error('Error parsing JSON string: $jsonString', e);
      return null;
    }
  }

  Future<void> loadMessagesForConversation(String otherDeviceId) async {
    try {
      final messages =
          MessageStorage.getMessagesForConversation(_otherDeviceId);
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      state = state.copyWith(messages: messages);
      Logger.info(
          'Loaded ${messages.length} messages for conversation with: $_otherDeviceId');
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
final chatProvider =
    StateNotifierProvider.family<ChatNotifier, ChatState, String>(
        (ref, otherDeviceId) {
  final connectionNotifier = ref.watch(connectionProvider.notifier);
  final myDeviceId = ref.watch(currentDeviceIdProvider);
  return ChatNotifier(connectionNotifier, ref, myDeviceId, otherDeviceId);
});
