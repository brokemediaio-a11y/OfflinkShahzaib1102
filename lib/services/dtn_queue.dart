import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';
import '../models/message_packet.dart';

/// SQLite-backed store-and-forward outbound queue.
///
/// When no route is available to the destination, packets are buffered here.
/// [DtnRetryLoop] polls this queue every 30 seconds and re-attempts delivery
/// when new peers come into range.
class DtnQueue {
  static const _maxAttempts = 20;         // give up after 20 retries
  static const _retryIntervalMs = 30000;  // retry every 30 seconds

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

  /// Record the result of a delivery attempt.
  ///
  /// If [delivered] is true, the row is deleted (delivery confirmed).
  /// If false, the attempt counter is incremented; the row is marked 'expired'
  /// once [_maxAttempts] is reached.
  static Future<void> recordAttempt(String msgId,
      {required bool delivered}) async {
    final db = await DatabaseHelper.database;
    if (delivered) {
      await db.delete('outbound_queue',
          where: 'msg_id = ?', whereArgs: [msgId]);
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

  /// Return the count of pending packets (for diagnostics / UI).
  static Future<int> getPendingCount() async {
    final db = await DatabaseHelper.database;
    final result = await db.rawQuery(
        "SELECT COUNT(*) as cnt FROM outbound_queue WHERE status = 'pending'");
    return (result.first['cnt'] as int?) ?? 0;
  }
}
