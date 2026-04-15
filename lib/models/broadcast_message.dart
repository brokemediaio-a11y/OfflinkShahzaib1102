import 'dart:convert';

/// A broadcast message sent to ALL reachable peers (not targeted to one user).
///
/// Wire format: [MessagePacket] with [type] = 'broadcast', [toUserId] = '*'.
/// The [payload] field is a JSON object:
/// ```json
/// { "text": "...", "senderName": "Alice", "lat": 1.234, "lng": 5.678 }
/// ```
/// lat/lng are optional — omitted when the sender chose not to share location.
class BroadcastMessage {
  /// Globally unique ID (= msgId from the wire packet).
  final String id;

  /// UUID of the originating device.
  final String fromUserId;

  /// Human-readable sender name (extracted from the packet payload).
  final String senderName;

  /// Broadcast text content.
  final String text;

  /// Optional GPS latitude of the sender at time of broadcast.
  final double? latitude;

  /// Optional GPS longitude of the sender at time of broadcast.
  final double? longitude;

  /// Unix timestamp (ms) set by the originator — never modified in transit.
  final int timestamp;

  /// Number of hops this message took to reach the local device.
  final int hopCount;

  /// True if THIS device originated the broadcast.
  final bool isSelf;

  const BroadcastMessage({
    required this.id,
    required this.fromUserId,
    required this.senderName,
    required this.text,
    this.latitude,
    this.longitude,
    required this.timestamp,
    this.hopCount = 0,
    this.isSelf = false,
  });

  DateTime get dateTime => DateTime.fromMillisecondsSinceEpoch(timestamp);
  bool get hasLocation => latitude != null && longitude != null;

  // ─── Parsing ─────────────────────────────────────────────────────────────

  /// Build from a `__broadcast__` event JSON emitted by [MeshHandler].
  ///
  /// The JSON structure:
  /// ```json
  /// {
  ///   "__type": "__broadcast__",
  ///   "msgId": "...",
  ///   "fromUserId": "...",
  ///   "payload": "{\"text\":\"...\",\"senderName\":\"...\"}",
  ///   "timestamp": 1234567890,
  ///   "hopCount": 2
  /// }
  /// ```
  factory BroadcastMessage.fromMeshEvent(Map<String, dynamic> json) {
    final payloadStr = json['payload'] as String? ?? '{}';
    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(payloadStr) as Map<String, dynamic>;
    } catch (_) {
      payload = {'text': payloadStr};
    }

    return BroadcastMessage(
      id: json['msgId'] as String,
      fromUserId: json['fromUserId'] as String,
      senderName: (payload['senderName'] as String?) ?? 'Unknown',
      text: (payload['text'] as String?) ?? '',
      latitude: (payload['lat'] as num?)?.toDouble(),
      longitude: (payload['lng'] as num?)?.toDouble(),
      timestamp: json['timestamp'] as int,
      hopCount: (json['hopCount'] as int?) ?? 0,
      isSelf: false,
    );
  }

  // ─── SQLite serialisation ─────────────────────────────────────────────────

  Map<String, dynamic> toDbMap() => {
        'id': id,
        'from_user_id': fromUserId,
        'sender_name': senderName,
        'text': text,
        'latitude': latitude,
        'longitude': longitude,
        'timestamp': timestamp,
        'hop_count': hopCount,
        'is_self': isSelf ? 1 : 0,
      };

  factory BroadcastMessage.fromDbMap(Map<String, dynamic> j) =>
      BroadcastMessage(
        id: j['id'] as String,
        fromUserId: j['from_user_id'] as String,
        senderName: j['sender_name'] as String? ?? 'Unknown',
        text: j['text'] as String? ?? '',
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        timestamp: j['timestamp'] as int,
        hopCount: j['hop_count'] as int? ?? 0,
        isSelf: (j['is_self'] as int?) == 1,
      );
}
