import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';
import '../models/message_packet.dart';

/// SQLite-backed store-and-forward outbound queue.
///
/// When no route is available to the destination, packets are buffered here.
/// [DtnRetryLoop] polls this queue every 30 seconds and re-attempts delivery
/// when new peers come into range.
class DtnQueue {
  static const _maxAttempts = 20; // give up after 20 retries
  static const _retryIntervalMs = 30000; // retry every 30 seconds

  /// Buffer a packet for later delivery. Ignores duplicates (idempotent).
  static Future<void> enqueue(MessagePacket packet) async {
    if (packet.isExpired) return; // never store TTL-expired packets
    final db = await DatabaseHelper.database;
    await db.insert(
      'outbound_queue',
      {
        'msg_id': packet.msgId,
        'to_user_id': packet.toUserId,
        'from_user_id': packet.fromUserId,
        'payload': packet.toWire(),
        'ttl': packet.ttl,
        'hop_count': packet.hopCount,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'attempts': 0,
        'status': 'pending',
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Get all packets that are due for a retry attempt right now.
  static Future<List<MessagePacket>> getPendingPackets() async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(
      'outbound_queue',
      where:
          "status = ? AND attempts < ? AND (last_attempt IS NULL OR last_attempt < ?)",
      whereArgs: ['pending', _maxAttempts, now - _retryIntervalMs],
    );
    return rows
        .map((r) => MessagePacket.fromWire(r['payload'] as String))
        .toList();
  }

  /// Get pending unicast packets for the DTN relay orchestrator.
  ///
  /// The pending-unicast loop uses [ignoreRetryThrottle] so a target coming
  /// back into range can be selected immediately by UUID. The actual socket
  /// connection is still guarded by ConnectionManager's DTN connection cooldown.
  static Future<List<MessagePacket>> getPendingUnicastPackets({
    bool ignoreRetryThrottle = false,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final throttleWhere = ignoreRetryThrottle
        ? ''
        : 'AND (last_attempt IS NULL OR last_attempt < ?)';
    final rows = await db.query(
      'outbound_queue',
      where: "status = ? AND attempts < ? AND to_user_id != '*' $throttleWhere",
      whereArgs: ignoreRetryThrottle
          ? ['pending', _maxAttempts]
          : ['pending', _maxAttempts, now - _retryIntervalMs],
    );
    return rows
        .map((r) => MessagePacket.fromWire(r['payload'] as String))
        .toList();
  }

  /// Record the result of a delivery attempt.
  ///
  /// If [delivered] is true, the row is deleted (delivery confirmed).
  /// If false, the attempt counter is incremented; the row is marked 'expired'
  /// once [_maxAttempts] is reached.
  static Future<void> recordAttempt(String msgId,
      {required bool delivered}) async {
    final db = await DatabaseHelper.database;
    if (delivered) {
      await db
          .delete('outbound_queue', where: 'msg_id = ?', whereArgs: [msgId]);
    } else {
      await db.rawUpdate('''
        UPDATE outbound_queue
        SET attempts     = attempts + 1,
            last_attempt = ?,
            status       = CASE WHEN attempts + 1 >= ? THEN 'expired' ELSE 'pending' END
        WHERE msg_id = ?
      ''', [DateTime.now().millisecondsSinceEpoch, _maxAttempts, msgId]);
    }
  }

  /// Record that a unicast packet was handed to a peer/relay, but not yet
  /// confirmed by the final destination. The ACK path is responsible for
  /// deleting the row when delivery is actually confirmed.
  static Future<void> recordHandoff(String msgId) async {
    final db = await DatabaseHelper.database;
    await db.rawUpdate('''
      UPDATE outbound_queue
      SET last_attempt = ?
      WHERE msg_id = ? AND to_user_id != '*'
    ''', [DateTime.now().millisecondsSinceEpoch, msgId]);
  }

  /// Remove expired / delivered rows older than 7 days.
  static Future<void> purgeExpired() async {
    final db = await DatabaseHelper.database;
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - (7 * 24 * 60 * 60 * 1000);
    await db.delete(
      'outbound_queue',
      where: "(status = 'expired' OR status = 'delivered') AND created_at < ?",
      whereArgs: [cutoff],
    );
  }

  // ── Broadcast-specific helpers ────────────────────────────────────────────

  /// Returns ALL pending broadcast packets created within the last 15 minutes,
  /// **without** the normal retry-throttle filter.
  ///
  /// Broadcasts must reach EVERY peer that comes online during the delivery
  /// window, not just the first one.  The 15-minute window limits the queue
  /// size while giving the DTN layer enough time to reach all visible peers.
  static Future<List<MessagePacket>> getPendingBroadcasts() async {
    final db = await DatabaseHelper.database;
    final cutoffMs = DateTime.now().millisecondsSinceEpoch - (15 * 60 * 1000);
    final rows = await db.query(
      'outbound_queue',
      where: "status = 'pending' AND to_user_id = '*' AND created_at >= ?",
      whereArgs: [cutoffMs],
    );
    return rows
        .map((r) => MessagePacket.fromWire(r['payload'] as String))
        .toList();
  }

  /// Record that a broadcast was sent to one peer.
  ///
  /// Unlike [recordAttempt], this does NOT delete the row — the broadcast
  /// must still be delivered to other peers.  It only updates [last_attempt]
  /// so that the 30-second retry-throttle in [getPendingPackets] still applies
  /// (though [getPendingBroadcasts] bypasses that throttle anyway).
  static Future<void> recordBroadcastSent(String msgId) async {
    final db = await DatabaseHelper.database;
    await db.rawUpdate('''
      UPDATE outbound_queue
      SET last_attempt = ?
      WHERE msg_id = ? AND to_user_id = '*'
    ''', [DateTime.now().millisecondsSinceEpoch, msgId]);
  }

  /// Remove pending broadcasts after a delivery round has reached every peer
  /// that was visible for that round. This prevents stale demo traffic from
  /// repeatedly auto-connecting devices after the user has moved on.
  static Future<void> clearPendingBroadcasts() async {
    final db = await DatabaseHelper.database;
    await db.delete(
      'outbound_queue',
      where: "to_user_id = '*' AND status = 'pending'",
    );
  }

  /// Expire all broadcast packets older than [window].
  /// Call this periodically (e.g., on app start) to keep the queue clean.
  static Future<void> expireStaleBroadcasts(
      {Duration window = const Duration(minutes: 15)}) async {
    final db = await DatabaseHelper.database;
    final cutoffMs =
        DateTime.now().millisecondsSinceEpoch - window.inMilliseconds;
    await db.rawUpdate('''
      UPDATE outbound_queue
      SET status = 'expired'
      WHERE to_user_id = '*' AND status = 'pending' AND created_at < ?
    ''', [cutoffMs]);
  }

  /// Return the count of pending packets (for diagnostics / UI).
  static Future<int> getPendingCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
        "SELECT COUNT(*) as cnt FROM outbound_queue WHERE status = 'pending'");
    return (result.first['cnt'] as int?) ?? 0;
  }

  // ── Debug helpers (hop-test branch only) ─────────────────────────────────

  /// Returns every row in the outbound queue (all statuses) for the debug panel.
  static Future<List<Map<String, dynamic>>> debugGetAllRows() async {
    final db = await DatabaseHelper.database;
    return db.query('outbound_queue', orderBy: 'created_at DESC');
  }

  /// Wipes the entire outbound queue. Test-only — use to reset between test runs.
  static Future<void> debugClearAll() async {
    final db = await DatabaseHelper.database;
    await db.delete('outbound_queue');
  }
}
