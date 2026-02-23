import 'package:hive/hive.dart';

part 'message_model.g.dart';

@HiveType(typeId: 0)
class MessageModel extends HiveObject {
  @HiveField(0)
  final String id; // Kept for backward compatibility, maps to messageId

  @HiveField(1)
  final String content;

  @HiveField(2)
  final String senderId; // Kept for backward compatibility, maps to originalSenderId

  @HiveField(3)
  final String receiverId; // Kept for backward compatibility, maps to finalReceiverId

  @HiveField(4)
  final DateTime timestamp;

  @HiveField(5)
  final MessageStatus status;

  @HiveField(6)
  final bool isSent;

  // New routing fields for mesh networking
  @HiveField(7)
  final String messageId; // Unique message identifier for deduplication

  @HiveField(8)
  final String originalSenderId; // Device that created the message

  @HiveField(9)
  final String finalReceiverId; // Intended destination device

  @HiveField(10)
  final int hopCount; // Number of hops taken

  @HiveField(11)
  final int maxHops; // Maximum hops allowed (TTL)

  MessageModel({
    required this.id,
    required this.content,
    required this.senderId,
    required this.receiverId,
    required this.timestamp,
    this.status = MessageStatus.sending,
    required this.isSent,
    // New routing fields with defaults
    String? messageId,
    String? originalSenderId,
    String? finalReceiverId,
    this.hopCount = 0,
    this.maxHops = 3,
  })  : messageId = messageId ?? id,
        originalSenderId = originalSenderId ?? senderId,
        finalReceiverId = finalReceiverId ?? receiverId;

  MessageModel copyWith({
    String? id,
    String? content,
    String? senderId,
    String? receiverId,
    DateTime? timestamp,
    MessageStatus? status,
    bool? isSent,
    String? messageId,
    String? originalSenderId,
    String? finalReceiverId,
    int? hopCount,
    int? maxHops,
  }) {
    return MessageModel(
      id: id ?? this.id,
      content: content ?? this.content,
      senderId: senderId ?? this.senderId,
      receiverId: receiverId ?? this.receiverId,
      timestamp: timestamp ?? this.timestamp,
      status: status ?? this.status,
      isSent: isSent ?? this.isSent,
      messageId: messageId ?? this.messageId,
      originalSenderId: originalSenderId ?? this.originalSenderId,
      finalReceiverId: finalReceiverId ?? this.finalReceiverId,
      hopCount: hopCount ?? this.hopCount,
      maxHops: maxHops ?? this.maxHops,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'content': content,
      'senderId': senderId,
      'receiverId': receiverId,
      'timestamp': timestamp.toIso8601String(),
      'status': status.name,
      'isSent': isSent,
      // Routing fields
      'messageId': messageId,
      'originalSenderId': originalSenderId,
      'finalReceiverId': finalReceiverId,
      'hopCount': hopCount,
      'maxHops': maxHops,
    };
  }

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    return MessageModel(
      id: json['id'] as String,
      content: json['content'] as String,
      senderId: json['senderId'] as String,
      receiverId: json['receiverId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      status: MessageStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => MessageStatus.sent,
      ),
      isSent: json['isSent'] as bool? ?? true,
      // Parse routing fields with fallbacks to legacy fields
      messageId: json['messageId'] as String? ?? json['id'] as String,
      originalSenderId: json['originalSenderId'] as String? ?? json['senderId'] as String,
      finalReceiverId: json['finalReceiverId'] as String? ?? json['receiverId'] as String,
      hopCount: json['hopCount'] as int? ?? 0,
      maxHops: json['maxHops'] as int? ?? 3,
    );
  }

  @override
  String toString() {
    return 'MessageModel(id: $id, messageId: $messageId, content: $content, senderId: $senderId, originalSenderId: $originalSenderId, receiverId: $receiverId, finalReceiverId: $finalReceiverId, timestamp: $timestamp, status: $status, isSent: $isSent, hopCount: $hopCount, maxHops: $maxHops)';
  }
}

@HiveType(typeId: 1)
enum MessageStatus {
  @HiveField(0)
  sending,
  @HiveField(1)
  sent,
  @HiveField(2)
  delivered,
  @HiveField(3)
  failed,
}




