import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Central SQLite database for all DTN networking/routing state.
///
/// Hive is kept for user profiles, chat history, and settings.
/// All routing tables, seen-message caches, and outbound queues live here.
class DatabaseHelper {
  static Database? _db;

  static Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      join(dbPath, 'offlink.db'),
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    // Outbound message queue — messages this device needs to send or relay
    await db.execute('''
      CREATE TABLE outbound_queue (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        msg_id       TEXT NOT NULL UNIQUE,
        to_user_id   TEXT NOT NULL,
        from_user_id TEXT NOT NULL,
        payload      TEXT NOT NULL,
        ttl          INTEGER NOT NULL DEFAULT 7,
        hop_count    INTEGER NOT NULL DEFAULT 0,
        created_at   INTEGER NOT NULL,
        last_attempt INTEGER,
        attempts     INTEGER NOT NULL DEFAULT 0,
        status       TEXT NOT NULL DEFAULT 'pending'
      )
    ''');

    // Seen message cache — prevents reprocessing / loops
    await db.execute('''
      CREATE TABLE seen_messages (
        msg_id     TEXT PRIMARY KEY,
        seen_at    INTEGER NOT NULL
      )
    ''');

    // Routing table — maps userId → bestNextHop (a deviceAddress we can reach)
    await db.execute('''
      CREATE TABLE routing_table (
        user_id          TEXT PRIMARY KEY,
        next_hop_address TEXT NOT NULL,
        hop_distance     INTEGER NOT NULL DEFAULT 1,
        last_seen        INTEGER NOT NULL,
        transport        TEXT NOT NULL DEFAULT 'wifi_direct'
      )
    ''');

    // Delivered messages log (for dedup on receiver side)
    await db.execute('''
      CREATE TABLE delivered_messages (
        msg_id       TEXT PRIMARY KEY,
        from_user_id TEXT NOT NULL,
        delivered_at INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    if (oldV < 3) {
      try {
        await db.execute(
            'ALTER TABLE outbound_queue ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0');
      } catch (_) {}
      try {
        await db.execute(
            'ALTER TABLE outbound_queue ADD COLUMN last_attempt INTEGER');
      } catch (_) {}
    }
  }
}
