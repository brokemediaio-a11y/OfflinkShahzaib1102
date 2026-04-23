import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';

/// SQLite-backed seen-message cache.
///
/// Every device MUST check this before processing any received packet.
/// This is the primary loop-prevention mechanism in the mesh.
class SeenCache {
  /// Keep seen entries for 48 hours before evicting.
  static const _ttlMs = 48 * 60 * 60 * 1000;

  /// Returns [true] if this [msgId] was already processed by this device.
  static Future<bool> hasSeen(String msgId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'seen_messages',
      where: 'msg_id = ?',
      whereArgs: [msgId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Record that [msgId] has been processed. Idempotent — safe to call twice.
  static Future<void> markSeen(String msgId) async {
    final db = await DatabaseHelper.database;
    await db.insert(
      'seen_messages',
      {'msg_id': msgId, 'seen_at': DateTime.now().millisecondsSinceEpoch},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Remove entries older than [_ttlMs]. Call periodically (e.g. every hour).
  static Future<void> evictExpired() async {
    final db = await DatabaseHelper.database;
    final cutoff = DateTime.now().millisecondsSinceEpoch - _ttlMs;
    await db.delete('seen_messages', where: 'seen_at < ?', whereArgs: [cutoff]);
  }

  // ── Debug helpers (hop-test branch only) ─────────────────────────────────

  /// Returns count of entries currently in the seen cache.
  static Future<int> debugGetCount() async {
    final db = await DatabaseHelper.database;
    final r = await db.rawQuery('SELECT COUNT(*) as cnt FROM seen_messages');
    return (r.first['cnt'] as int?) ?? 0;
  }

  /// Wipes the seen cache. Test-only — allows re-delivering the same message.
  static Future<void> debugClearAll() async {
    final db = await DatabaseHelper.database;
    await db.delete('seen_messages');
  }
}
