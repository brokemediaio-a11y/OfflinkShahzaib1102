import 'package:hive/hive.dart';

part 'conversation_model.g.dart';

@HiveType(typeId: 2)
class ConversationModel extends HiveObject {
  @HiveField(0)
  final String deviceId; // The other device's ID
  
  @HiveField(1)
  final String deviceName; // The other device's name
  
  @HiveField(2)
  final String lastMessage; // Last message content
  
  @HiveField(3)
  final DateTime lastMessageTime; // Timestamp of last message
  
  @HiveField(4)
  final int unreadCount; // Number of unread messages
  
  @HiveField(5)
  final bool isConnected; // Whether currently connected to this device

  ConversationModel({
    required this.deviceId,
    required this.deviceName,
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.isConnected = false,
  });

  ConversationModel copyWith({
    String? deviceId,
    String? deviceName,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    bool? isConnected,
  }) {
    return ConversationModel(
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      isConnected: isConnected ?? this.isConnected,
    );
  }
}