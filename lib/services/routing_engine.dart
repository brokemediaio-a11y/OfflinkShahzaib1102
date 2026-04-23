import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';

/// A currently-reachable peer known to this device.
class PeerInfo {
  final String userId;
  final String address;   // IP for Wi-Fi Direct, MAC for BLE
  final String transport; // 'wifi_direct' | 'ble'

  const PeerInfo({
    required this.userId,
    required this.address,
    required this.transport,
  });
}

enum RouteType { direct, relay, store }

class RouteDecision {
  final RouteType type;
  final String? nextHopAddress; // device-level address (Wi-Fi Direct IP or BLE MAC)
  final String transport;       // 'wifi_direct' | 'ble'

  const RouteDecision({
    required this.type,
    this.nextHopAddress,
    this.transport = 'wifi_direct',
  });
}

/// SQLite-backed routing engine.
///
/// Decides how to deliver a packet given the set of currently reachable peers:
///   1. [RouteType.direct]  — recipient is directly reachable right now.
///   2. [RouteType.relay]   — a known relay peer can reach the recipient.
///   3. [RouteType.store]   — no route known; buffer in [DtnQueue].
class RoutingEngine {
  /// Decide how to deliver a packet to [toUserId].
  ///
  /// [connectedPeers] — map of {userId → PeerInfo} for devices currently
  /// reachable by this device.
  static Future<RouteDecision> resolve({
    required String toUserId,
    required Map<String, PeerInfo> connectedPeers,
  }) async {
    // 1. Direct: is the recipient in our connected peers right now?
    if (connectedPeers.containsKey(toUserId)) {
      final peer = connectedPeers[toUserId]!;
      return RouteDecision(
        type: RouteType.direct,
        nextHopAddress: peer.address,
        transport: peer.transport,
      );
    }

    // 2. Relay: do any of our connected peers know a route to toUserId?
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'routing_table',
      where: 'user_id = ?',
      whereArgs: [toUserId],
      orderBy: 'hop_distance ASC',
      limit: 1,
    );

    if (rows.isNotEmpty) {
      final nextHop = rows.first['next_hop_address'] as String;
      // Verify next hop is still reachable
      final isReachable =
          connectedPeers.values.any((p) => p.address == nextHop);
      if (isReachable) {
        return RouteDecision(
          type: RouteType.relay,
          nextHopAddress: nextHop,
          transport: rows.first['transport'] as String,
        );
      }
    }

    // 3. Store: nobody nearby knows how to reach toUserId — buffer it
    return const RouteDecision(type: RouteType.store);
  }

  /// Update routing table when we learn a peer can reach [userId] via [nextHopAddress].
  static Future<void> learnRoute({
    required String userId,
    required String nextHopAddress,
    required int hopDistance,
    required String transport,
  }) async {
    final db = await DatabaseHelper.database;
    await db.insert(
      'routing_table',
      {
        'user_id': userId,
        'next_hop_address': nextHopAddress,
        'hop_distance': hopDistance,
        'last_seen': DateTime.now().millisecondsSinceEpoch,
        'transport': transport,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Remove stale routes (device hasn't been seen in 30 minutes).
  static Future<void> evictStaleRoutes() async {
    final db = await DatabaseHelper.database;
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - (30 * 60 * 1000);
    await db.delete('routing_table',
        where: 'last_seen < ?', whereArgs: [cutoff]);
  }

  // ── Debug helpers (hop-test branch only) ─────────────────────────────────

  /// Returns every row in the routing table for the debug panel.
  static Future<List<Map<String, dynamic>>> debugGetAllRoutes() async {
    final db = await DatabaseHelper.database;
    return db.query('routing_table', orderBy: 'hop_distance ASC');
  }

  /// Wipes the routing table. Test-only.
  static Future<void> debugClearAll() async {
    final db = await DatabaseHelper.database;
    await db.delete('routing_table');
  }
}
