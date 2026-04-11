import 'dart:convert';

/// Network wire format for the DTN mesh layer.
///
/// This is the packet that travels over the air (BLE or Wi-Fi Direct).
/// It is separate from [MessageModel], which is the local storage / UI model.
///
/// Conversion:
///   Outbound: build a [MessagePacket] from the user's text + routing info.
///   Inbound:  [MeshHandler] converts to [MessageModel]-format JSON for the UI.
class MessagePacket {
  final String msgId;       // UUID v4, globally unique
  final String toUserId;    // stable userId of intended recipient
  final String fromUserId;  // stable userId of originator
  final String payload;     // message text (or JSON for future media)
  final int ttl;            // decremented at each hop; drop at 0
  final int hopCount;       // incremented at each hop (for diagnostics)
  final int timestamp;      // Unix ms, set by originator — NEVER changed in transit
  final String type;        // 'message' | 'ack' | 'route_advert'

  const MessagePacket({
    required this.msgId,
    required this.toUserId,
    required this.fromUserId,
    required this.payload,
    required this.ttl,
    required this.hopCount,
    required this.timestamp,
    this.type = 'message',
  });

  /// Create a copy with decremented TTL and incremented hop count.
  /// Call this before forwarding to a relay node.
  MessagePacket hop() => MessagePacket(
        msgId: msgId,
        toUserId: toUserId,
        fromUserId: fromUserId,
        payload: payload,
        ttl: ttl - 1,
        hopCount: hopCount + 1,
        timestamp: timestamp,
        type: type,
      );

  bool get isExpired => ttl <= 0;

  Map<String, dynamic> toJson() => {
        'msgId': msgId,
        'toUserId': toUserId,
        'fromUserId': fromUserId,
        'payload': payload,
        'ttl': ttl,
        'hopCount': hopCount,
        'timestamp': timestamp,
        'type': type,
      };

  factory MessagePacket.fromJson(Map<String, dynamic> j) => MessagePacket(
        msgId: j['msgId'] as String,
        toUserId: j['toUserId'] as String,
        fromUserId: j['fromUserId'] as String,
        payload: j['payload'] as String,
        ttl: j['ttl'] as int,
        hopCount: (j['hopCount'] as int?) ?? 0,
        timestamp: j['timestamp'] as int,
        type: (j['type'] as String?) ?? 'message',
      );

  String toWire() => jsonEncode(toJson());

  static MessagePacket fromWire(String raw) =>
      MessagePacket.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// Returns true if a JSON map looks like a [MessagePacket] wire format.
  /// Used to distinguish packets from legacy [MessageModel] JSON in the receive path.
  static bool looksLikePacket(Map<String, dynamic> json) =>
      json.containsKey('msgId') && json.containsKey('toUserId') && json.containsKey('fromUserId');
}
