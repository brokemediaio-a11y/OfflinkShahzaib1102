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

  // ── Routing fields for mesh networking ────────────────────────────

  @HiveField(7)
  final String messageId; // Unique message identifier for deduplication

  @HiveField(8)
  final String originalSenderId; // Device that created the message

  @HiveField(9)
  final String finalReceiverId; // Intended destination device

  @HiveField(10)
  final int hopCount; // Number of hops taken (incremented at each relay)

  @HiveField(11)
  final int maxHops; // Maximum hops allowed (TTL — default: 5)

  @HiveField(12)
  final String? senderPeerId; // The immediate peer that sent/forwarded this message to us
                               // Used to avoid echoing messages back to the sender

  MessageModel({
    required this.id,
    required this.content,
    required this.senderId,
    required this.receiverId,
    required this.timestamp,
    this.status = MessageStatus.sending,
    required this.isSent,
    // Routing fields with defaults
    String? messageId,
    String? originalSenderId,
    String? finalReceiverId,
    this.hopCount = 0,
    this.maxHops = 5,
    this.senderPeerId,
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
    String? senderPeerId,
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
      senderPeerId: senderPeerId ?? this.senderPeerId,
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
      'senderPeerId': senderPeerId,
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
      originalSenderId:
          json['originalSenderId'] as String? ?? json['senderId'] as String,
      finalReceiverId:
          json['finalReceiverId'] as String? ?? json['receiverId'] as String,
      hopCount: json['hopCount'] as int? ?? 0,
      maxHops: json['maxHops'] as int? ?? 5,
      senderPeerId: json['senderPeerId'] as String?,
    );
  }

  @override
  String toString() {
    return 'MessageModel(messageId: $messageId, content: $content, '
        'from: $originalSenderId → to: $finalReceiverId, '
        'hop: $hopCount/$maxHops, status: ${status.name}, '
        'isSent: $isSent)';
  }
}

@HiveType(typeId: 1)
enum MessageStatus {
  @HiveField(0)
  sending, // Being sent right now

  @HiveField(1)
  sent, // Delivered to immediate connected peer

  @HiveField(2)
  delivered, // Confirmed received by the final destination (via ACK)

  @HiveField(3)
  failed, // Send attempt failed

  @HiveField(4)
  pending, // Queued locally — peer offline, waiting for a relay connection

  @HiveField(5)
  relayed, // Forwarded to a relay node — en route to final destination
}
