import 'package:sqflite/sqflite.dart';
import '../database_helper.dart';
import '../../models/broadcast_message.dart';

/// SQLite-backed storage for [BroadcastMessage]s.
///
/// Table is created lazily on first access (same CREATE TABLE IF NOT EXISTS
/// pattern used by DtnQueue, SeenCache, and RoutingEngine — no version bump
/// required for the central DatabaseHelper).
class BroadcastStorage {
  static const _table = 'broadcast_messages';

  // ─── Schema ──────────────────────────────────────────────────────────────

  static Future<void> _ensureTable() async {
    final db = await DatabaseHelper.database;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_table (
        id           TEXT PRIMARY KEY,
        from_user_id TEXT NOT NULL,
        sender_name  TEXT NOT NULL DEFAULT '',
        text         TEXT NOT NULL DEFAULT '',
        latitude     REAL,
        longitude    REAL,
        timestamp    INTEGER NOT NULL,
        hop_count    INTEGER NOT NULL DEFAULT 0,
        is_self      INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  // ─── Write ────────────────────────────────────────────────────────────────

  /// Persist a [BroadcastMessage].  Silently ignores duplicates (CONFLICT IGNORE).
  static Future<void> save(BroadcastMessage msg) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    await db.insert(
      _table,
      msg.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ─── Read ─────────────────────────────────────────────────────────────────

  /// Load all broadcasts, newest first (max [limit] rows).
  static Future<List<BroadcastMessage>> getAll({int limit = 200}) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      _table,
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return rows.map(BroadcastMessage.fromDbMap).toList();
  }

  // ─── Housekeeping ─────────────────────────────────────────────────────────

  /// Delete broadcasts older than [age] to keep the database trim.
  static Future<void> deleteOlderThan(Duration age) async {
    await _ensureTable();
    final db = await DatabaseHelper.database;
    final cutoff = DateTime.now().subtract(age).millisecondsSinceEpoch;
    await db.delete(_table, where: 'timestamp < ?', whereArgs: [cutoff]);
  }
}
