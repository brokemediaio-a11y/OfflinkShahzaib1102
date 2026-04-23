import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/message_packet.dart';
import '../utils/logger.dart';
import 'seen_cache.dart';
import 'routing_engine.dart';
import 'dtn_queue.dart';
import 'database_helper.dart';

/// Core DTN mesh relay logic.
///
/// Every packet received from any transport passes through [onRawReceived].
/// Every new outbound message from the UI passes through [sendMessage].
///
/// Transport-agnostic: uses injected callbacks so [ConnectionManager] can
/// swap the underlying radio without touching routing.
///
/// Delivered packets are emitted on [deliveredMessages] as
/// [MessageModel]-compatible JSON strings so the existing UI pipeline
/// (ConnectionProvider → ChatNotifier) works unchanged.
///
/// Broadcast packets (type == 'broadcast', toUserId == '*') are delivered
/// locally AND forwarded to every reachable neighbour via [broadcastViaTransport].
///
/// ## Range Extension (Feature 5)
///
/// Physical range is extended through **multi-hop mesh relay**, not by
/// increasing radio power beyond safe/permitted limits:
///   - Single-hop BLE range: ~10–30 m (real-world)
///   - Single-hop WiFi Direct range: ~50 m
///   - Effective logical range = sum of relay hops × single-hop range
///   - With TTL=5 and mesh relay, broadcasts can theoretically reach
///     peers 5× the single-hop distance away (250+ m indoors).
///
/// Each relay hop is transparent to the sender and receiver — the MeshHandler
/// on each intermediate node decrements TTL, increments hopCount, checks
/// SeenCache, and forwards to the best next hop via [RoutingEngine].
class MeshHandler {
  final String myUserId;

  /// Sends serialised wire data to the currently connected peer.
  /// Returns true if the send succeeded.
  final Future<bool> Function(String wireData) _sendViaTransport;

  /// Broadcasts serialised wire data to ALL registered neighbours.
  /// Returns the number of successful sends (0 = no peers / all failed).
  final Future<int> Function(String wireData) _broadcastViaTransport;

  // ── Output stream ─────────────────────────────────────────────────────
  final _deliveredController = StreamController<String>.broadcast();

  /// Emits [MessageModel]-format JSON for unicast messages delivered here.
  /// Emits `__delivery_ack__` JSON when an ACK packet arrives.
  /// Emits `__broadcast__` JSON when a broadcast packet arrives.
  Stream<String> get deliveredMessages => _deliveredController.stream;

  MeshHandler({
    required this.myUserId,
    required Future<bool> Function(String wireData) sendViaTransport,
    required Future<int> Function(String wireData) broadcastViaTransport,
  })  : _sendViaTransport = sendViaTransport,
        _broadcastViaTransport = broadcastViaTransport;

  // ═══════════════════════════════════════════════════════════════════════
  // Receive path
  // ═══════════════════════════════════════════════════════════════════════

  /// Entry point for every incoming raw wire string from any transport.
  Future<void> onRawReceived(
    String raw, {
    required Map<String, PeerInfo> currentPeers,
  }) async {
    MessagePacket packet;
    try {
      packet = MessagePacket.fromWire(raw);
    } catch (e) {
      Logger.warning('[MeshHandler] Failed to parse packet: $e');
      return;
    }

    // ── Broadcast packets ────────────────────────────────────────────
    if (packet.type == 'broadcast') {
      await _handleIncomingBroadcast(packet, currentPeers);
      return;
    }

    // ── Route adverts — processed separately, no dedup needed ────────
    if (packet.type == 'route_advert') {
      await _processRouteAdvert(packet, currentPeers);
      return;
    }

    // Step 1: Dedup
    if (await SeenCache.hasSeen(packet.msgId)) {
      if (packet.toUserId == myUserId && packet.type != 'ack') {
        Logger.debug(
            '[MeshHandler] Already delivered ${packet.msgId} - resending ACK');
        await _sendAck(packet, currentPeers);
      } else {
        Logger.debug('[MeshHandler] Already seen ${packet.msgId} - dropping');
      }
      return;
    }
    await SeenCache.markSeen(packet.msgId);

    // Step 2: Am I the destination?
    if (packet.toUserId == myUserId) {
      final via = packet.hopCount == 0 ? 'direct' : '${packet.hopCount}-hop relay';
      Logger.deliver(
          'ARRIVED  | ${packet.msgId.substring(0, 8)} | from=${packet.fromUserId.substring(0, 8)} '
          '| $via | ttl=${packet.ttl}');
      await _deliverToSelf(packet);
      // Never ACK an ACK — that ping-pongs forever (msgId becomes _ack_ack_…).
      if (packet.type != 'ack') {
        await _sendAck(packet, currentPeers);
      }
      return;
    }

    // Step 3: TTL check
    if (packet.isExpired) {
      Logger.warning(
          '⏱️ TTL_EXHAUSTED | ${packet.msgId.substring(0, 8)} | hop=${packet.hopCount} '
          '| ${packet.fromUserId.substring(0, 8)} → ${packet.toUserId.substring(0, 8)}');
      return;
    }

    // Step 4: Store for the relay orchestrator.
    //
    // Important: at receive time the active socket is the previous hop
    // (for example A -> B). Sending immediately here writes back to that same
    // socket instead of connecting to the real destination (B -> C). Queue the
    // hopped packet so ConnectionManager can disconnect from the sender, choose
    // the destination/next carrier by UUID, then flush it over the next socket.
    Logger.hop(
        'RELAY  | hop ${packet.hopCount} → ${packet.hopCount + 1} '
        '| ${packet.msgId.substring(0, 8)} '
        '| ${packet.fromUserId.substring(0, 8)} → ${packet.toUserId.substring(0, 8)} '
        '| ttl=${packet.ttl}');
    final hopped = packet.hop();
    await DtnQueue.enqueue(hopped);
    Logger.dtnLog(
        'QUEUED (relay carry) | ${hopped.msgId.substring(0, 8)} '
        '| to=${hopped.toUserId.substring(0, 8)} | hop=${hopped.hopCount}');
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Broadcast receive path
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _handleIncomingBroadcast(
    MessagePacket packet,
    Map<String, PeerInfo> currentPeers,
  ) async {
    // Dedup — SeenCache prevents the same broadcast looping back.
    if (await SeenCache.hasSeen(packet.msgId)) {
      Logger.debug('[BROADCAST][MeshHandler] Already seen ${packet.msgId} — dropping');
      return;
    }
    await SeenCache.markSeen(packet.msgId);

    // Deliver locally if this device didn't originate it.
    // (We already show our own sent broadcasts in BroadcastProvider.)
    if (packet.fromUserId != myUserId) {
      Logger.info(
          '[BROADCAST][MeshHandler] Delivering ${packet.msgId} locally '
          '(from=${packet.fromUserId} hop=${packet.hopCount})');
      await _deliverBroadcastToSelf(packet);
    }

    // TTL check before relaying.
    if (packet.isExpired) {
      Logger.warning(
          '[BROADCAST][MeshHandler] ${packet.msgId} TTL exhausted — not relaying');
      return;
    }

    // Relay to all neighbours (hop-decremented copy).
    final hopped = packet.hop();
    final sentCount = await _broadcastViaTransport(hopped.toWire());
    Logger.info(
        '[BROADCAST][MeshHandler] Relayed ${packet.msgId} to $sentCount neighbour(s) '
        '(ttl=${hopped.ttl} hop=${hopped.hopCount})');
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Send path (outbound from UI)
  // ═══════════════════════════════════════════════════════════════════════

  /// Route a new outbound [packet] created by this device's user.
  ///
  /// For **broadcast** packets ([toUserId] == '*', [type] == 'broadcast'):
  ///   - Marks msgId in SeenCache (prevents echo-back).
  ///   - Sends to all neighbours via [_broadcastViaTransport].
  ///   - Queues in [DtnQueue] if no neighbours are reachable right now.
  ///
  /// For **unicast** packets: uses [RoutingEngine] to pick a next hop.
  ///
  /// Returns true if sent over the air now; false if queued in [DtnQueue].
  Future<bool> sendMessage({
    required MessagePacket packet,
    required Map<String, PeerInfo> currentPeers,
  }) async {
    // ── Broadcast fast path ───────────────────────────────────────────
    if (packet.toUserId == '*' && packet.type == 'broadcast') {
      await SeenCache.markSeen(packet.msgId); // prevent loop-back if we receive our own
      final sentCount = await _broadcastViaTransport(packet.toWire());
      if (sentCount == 0) {
        await DtnQueue.enqueue(packet);
        Logger.info(
            '[BROADCAST][MeshHandler] $myUserId | ${packet.msgId} | '
            'NO_PEERS_QUEUED');
        return false;
      }
      Logger.info(
          '[BROADCAST][MeshHandler] $myUserId | ${packet.msgId} | '
          'SENT to $sentCount peer(s)');
      return true;
    }

    // ── Unicast path (original logic) ────────────────────────────────
    await SeenCache.markSeen(packet.msgId); // prevent loop-back

    final decision = await RoutingEngine.resolve(
      toUserId: packet.toUserId,
      connectedPeers: currentPeers,
    );

    switch (decision.type) {
      case RouteType.direct:
      case RouteType.relay:
        final sent = await _sendViaTransport(packet.toWire());
        if (!sent) {
          await DtnQueue.enqueue(packet);
          Logger.dtnLog(
              'QUEUED (send failed) | ${packet.msgId.substring(0, 8)} '
              '| to=${packet.toUserId.substring(0, 8)} | route=${decision.type.name}');
          return false;
        }
        Logger.hop(
            'SENT  | ${packet.msgId.substring(0, 8)} '
            '| to=${packet.toUserId.substring(0, 8)} | route=${decision.type.name}');
        return true;

      case RouteType.store:
        Logger.dtnLog(
            'QUEUED (no route) | ${packet.msgId.substring(0, 8)} '
            '| to=${packet.toUserId.substring(0, 8)}');
        await DtnQueue.enqueue(packet);
        return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Forward — used by receive path AND DtnRetryLoop
  // ═══════════════════════════════════════════════════════════════════════

  /// Public entry point used by [DtnRetryLoop] to retry buffered packets.
  Future<bool> forward(
          MessagePacket packet, Map<String, PeerInfo> currentPeers) =>
      _forward(packet, currentPeers);

  Future<bool> _forward(
      MessagePacket packet, Map<String, PeerInfo> currentPeers) async {
    // ── Broadcast retry path ─────────────────────────────────────────
    if (packet.toUserId == '*' && packet.type == 'broadcast') {
      final sentCount = await _broadcastViaTransport(packet.toWire());
      if (sentCount == 0) {
        await DtnQueue.enqueue(packet); // CONFLICT IGNORE — already queued
        return false;
      }
      Logger.info(
          '[BROADCAST][MeshHandler] ↗️ Retried ${packet.msgId} to $sentCount peer(s)');
      return true;
    }

    // ── Unicast forward path (original logic) ────────────────────────
    final decision = await RoutingEngine.resolve(
      toUserId: packet.toUserId,
      connectedPeers: currentPeers,
    );

    switch (decision.type) {
      case RouteType.direct:
      case RouteType.relay:
        final sent = await _sendViaTransport(packet.toWire());
        if (!sent) {
          await DtnQueue.enqueue(packet);
          return false;
        }
        Logger.hop(
            'FORWARDED | ${packet.msgId.substring(0, 8)} | hop=${packet.hopCount}');
        return true;

      case RouteType.store:
        Logger.dtnLog(
            'QUEUED (forward, no route) | ${packet.msgId.substring(0, 8)}');
        await DtnQueue.enqueue(packet);
        return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Local delivery — unicast
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _deliverToSelf(MessagePacket packet) async {
    if (packet.type != 'ack') {
      final via = packet.hopCount == 0
          ? 'direct'
          : '${packet.hopCount}-hop relay';
      Logger.deliver(
          'DELIVER | ${packet.msgId.substring(0, 8)} | from=${packet.fromUserId.substring(0, 8)} | $via');
    }

    if (packet.type == 'ack') {
      // Emit as __delivery_ack__ so ConnectionProvider updates status
      final ackJson = jsonEncode({
        '__type': '__delivery_ack__',
        'messageId': packet.payload, // payload = original msgId
        'originalSenderId': packet.fromUserId,
        'finalReceiverId': myUserId,
        'ackSenderId': packet.fromUserId,
        'timestamp': DateTime.fromMillisecondsSinceEpoch(packet.timestamp)
            .toIso8601String(),
      });
      _deliveredController.add(ackJson);
      return;
    }

    // Convert to MessageModel-format JSON for the existing UI pipeline.
    // ConnectionProvider.handleIncomingMessageGlobally() reads this format.
    final modelJson = jsonEncode({
      'id': packet.msgId,
      'content': packet.payload,
      'senderId': packet.fromUserId,
      'receiverId': myUserId,
      'timestamp':
          DateTime.fromMillisecondsSinceEpoch(packet.timestamp).toIso8601String(),
      'status': 'delivered',
      'isSent': false,
      'messageId': packet.msgId,
      'originalSenderId': packet.fromUserId,
      'finalReceiverId': myUserId,
      'hopCount': packet.hopCount,
      'maxHops': 7,
      'senderPeerId': null,
    });
    _deliveredController.add(modelJson);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Local delivery — broadcast
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _deliverBroadcastToSelf(MessagePacket packet) async {
    // Emit a special event type so ConnectionProvider can route this to
    // BroadcastProvider without trying to parse it as a MessageModel.
    final eventJson = jsonEncode({
      '__type': '__broadcast__',
      'msgId': packet.msgId,
      'fromUserId': packet.fromUserId,
      'payload': packet.payload, // raw JSON: { "text", "senderName", "lat"?, "lng"? }
      'timestamp': packet.timestamp,
      'hopCount': packet.hopCount,
    });
    _deliveredController.add(eventJson);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // ACK
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _sendAck(
      MessagePacket original, Map<String, PeerInfo> currentPeers) async {
    final ack = MessagePacket(
      msgId: '${original.msgId}_ack',
      toUserId: original.fromUserId,
      fromUserId: myUserId,
      payload: original.msgId, // tell sender which message was received
      ttl: 7,
      hopCount: 0,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      type: 'ack',
    );
    await _forward(ack, currentPeers);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Route advertisement
  // ═══════════════════════════════════════════════════════════════════════

  /// Send our routing table to [toPeer] immediately after they connect.
  /// Called via [PeerDiscovery.onPeerAdded].
  Future<void> sendRouteAdvert(PeerInfo toPeer) async {
    try {
      final db = await DatabaseHelper.database;
      final rows = await db.query('routing_table', columns: ['user_id']);
      final knownUsers = rows.map((r) => r['user_id'] as String).toList();
      knownUsers.add(myUserId); // we always know ourselves

      final advert = MessagePacket(
        msgId: const Uuid().v4(),
        toUserId: '*',
        fromUserId: myUserId,
        payload: jsonEncode({'knownUsers': knownUsers}),
        ttl: 3,
        hopCount: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        type: 'route_advert',
      );

      await _sendViaTransport(advert.toWire());
      Logger.info(
          '[MeshHandler] 📡 Route advert sent to ${toPeer.userId} '
          '(${knownUsers.length} routes)');
    } catch (e) {
      Logger.error('[MeshHandler] Error sending route advert', e);
    }
  }

  Future<void> _processRouteAdvert(
    MessagePacket packet,
    Map<String, PeerInfo> currentPeers,
  ) async {
    try {
      PeerInfo? senderPeer;
      for (final p in currentPeers.values) {
        if (p.userId == packet.fromUserId) {
          senderPeer = p;
          break;
        }
      }
      if (senderPeer == null) return;

      final body = jsonDecode(packet.payload) as Map<String, dynamic>;
      final knownUsers = (body['knownUsers'] as List).cast<String>();

      for (final userId in knownUsers) {
        if (userId == myUserId) continue;
        await RoutingEngine.learnRoute(
          userId: userId,
          nextHopAddress: senderPeer.address,
          hopDistance: packet.hopCount + 1,
          transport: senderPeer.transport,
        );
      }

      Logger.info(
          '[MeshHandler] 📖 Learned ${knownUsers.length} routes from ${packet.fromUserId}');
    } catch (e) {
      Logger.error('[MeshHandler] Error processing route advert', e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Lifecycle
  // ═══════════════════════════════════════════════════════════════════════

  void dispose() => _deliveredController.close();
}
