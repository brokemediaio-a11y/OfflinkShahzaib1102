import 'package:hive_flutter/hive_flutter.dart';
import '../../models/message_model.dart';
import '../../core/constants.dart';
import '../../utils/logger.dart';

class MessageStorage {
  static Box<MessageModel>? _messagesBox;

  static Future<void> init() async {
    try {
      _messagesBox = await Hive.openBox<MessageModel>(AppConstants.messagesBoxName);
      Logger.info('Message storage initialized');
    } catch (e) {
      Logger.error('Error initializing message storage', e);
      rethrow;
    }
  }

  // Save a message
  static Future<void> saveMessage(MessageModel message) async {
    try {
      await _messagesBox?.put(message.id, message);
      Logger.debug('Message saved: ${message.id}');
    } catch (e) {
      Logger.error('Error saving message', e);
      rethrow;
    }
  }

  // Get all messages
  static List<MessageModel> getAllMessages() {
    try {
      return _messagesBox?.values.toList() ?? [];
    } catch (e) {
      Logger.error('Error getting all messages', e);
      return [];
    }
  }

  // Get messages for a specific conversation
  // Matches messages where the other device is either sender or receiver
  static List<MessageModel> getMessagesForConversation(String otherDeviceId) {
    try {
      final allMessages = _messagesBox?.values.toList() ?? [];
      // Filter messages where the other device is involved
      // Either the other device sent to us, or we sent to the other device
      final conversationMessages = allMessages.where((message) {
        // Match if other device is sender (we received from them)
        // OR if other device is receiver (we sent to them)
        return message.senderId == otherDeviceId || 
               message.receiverId == otherDeviceId;
      }).toList();
      
      // Sort by timestamp
      conversationMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      
      return conversationMessages;
    } catch (e) {
      Logger.error('Error getting messages for conversation', e);
      return [];
    }
  }

  // Update message status
  static Future<void> updateMessageStatus(
      String messageId, MessageStatus status) async {
    try {
      final message = _messagesBox?.get(messageId);
      if (message != null) {
        await _messagesBox?.put(
            messageId, message.copyWith(status: status));
        Logger.debug('Message status updated: $messageId -> ${status.name}');
      }
    } catch (e) {
      Logger.error('Error updating message status', e);
      rethrow;
    }
  }

  // Delete a message
  static Future<void> deleteMessage(String messageId) async {
    try {
      await _messagesBox?.delete(messageId);
      Logger.debug('Message deleted: $messageId');
    } catch (e) {
      Logger.error('Error deleting message', e);
      rethrow;
    }
  }

  // Clear all messages
  static Future<void> clearAllMessages() async {
    try {
      await _messagesBox?.clear();
      Logger.info('All messages cleared');
    } catch (e) {
      Logger.error('Error clearing messages', e);
      rethrow;
    }
  }

  // Get message count
  static int getMessageCount() {
    return _messagesBox?.length ?? 0;
  }
}




