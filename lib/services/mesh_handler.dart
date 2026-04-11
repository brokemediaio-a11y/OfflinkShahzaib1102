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
/// Transport-agnostic: uses an injected [_sendViaTransport] callback so
/// [ConnectionManager] can swap the underlying radio without touching routing.
///
/// Delivered packets are emitted on [deliveredMessages] as
/// [MessageModel]-compatible JSON strings so the existing UI pipeline
/// (ConnectionProvider → ChatNotifier) works unchanged.
///
/// ## Range Extension (Feature 5)
///
/// Physical range is extended through **multi-hop mesh relay**, not by
/// increasing radio power beyond safe/permitted limits:
///   - Single-hop BLE range: ~10–30 m (real-world)
///   - Single-hop WiFi Direct range: ~50 m
///   - Effective logical range = sum of relay hops × single-hop range
///   - With TTL=7 and mesh relay, theoretical range is 7× the single-hop distance
///
/// Each relay hop is transparent to the sender and receiver — the MeshHandler
/// on each intermediate node decrements TTL, increments hopCount, checks
/// SeenCache, and forwards to the best next hop via [RoutingEngine].
class MeshHandler {
  final String myUserId;

  /// Sends serialised wire data to the currently connected peer.
  /// Returns true if the send succeeded.
  final Future<bool> Function(String wireData) _sendViaTransport;

  // ── Output stream ─────────────────────────────────────────────────────
  final _deliveredController = StreamController<String>.broadcast();

  /// Emits [MessageModel]-format JSON for messages delivered to this device.
  /// Also emits [__delivery_ack__]-type JSON when an ACK packet arrives.
  Stream<String> get deliveredMessages => _deliveredController.stream;

  MeshHandler({
    required this.myUserId,
    required Future<bool> Function(String wireData) sendViaTransport,
  }) : _sendViaTransport = sendViaTransport;

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

    // Route adverts are processed separately — no dedup needed
    if (packet.type == 'route_advert') {
      await _processRouteAdvert(packet, currentPeers);
      return;
    }

    // Step 1: Dedup
    if (await SeenCache.hasSeen(packet.msgId)) {
      Logger.debug('[MeshHandler] Already seen ${packet.msgId} — dropping');
      return;
    }
    await SeenCache.markSeen(packet.msgId);

    // Step 2: Am I the destination?
    if (packet.toUserId == myUserId) {
      Logger.info(
          '[HOP][MeshHandler] $myUserId | ${packet.msgId} | DELIVER_LOCAL | '
          'from=${packet.fromUserId} hop=${packet.hopCount} ttl=${packet.ttl}');
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
          '[HOP][MeshHandler] $myUserId | ${packet.msgId} | TTL_EXHAUSTED | '
          'from=${packet.fromUserId} to=${packet.toUserId} hop=${packet.hopCount}');
      return;
    }

    // Step 4: Forward
    Logger.info(
        '[HOP][MeshHandler] $myUserId | ${packet.msgId} | RELAY_FORWARD | '
        'from=${packet.fromUserId} to=${packet.toUserId} hop=${packet.hopCount} ttl=${packet.ttl}');
    final hopped = packet.hop();
    await _forward(hopped, currentPeers);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Send path (outbound from UI)
  // ═══════════════════════════════════════════════════════════════════════

  /// Route a new outbound [packet] created by this device's user.
  ///
  /// Returns true if sent over the air now; false if queued in [DtnQueue].
  Future<bool> sendMessage({
    required MessagePacket packet,
    required Map<String, PeerInfo> currentPeers,
  }) async {
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
          Logger.info(
              '[DTN][MeshHandler] $myUserId | ${packet.msgId} | SEND_FAILED_QUEUED | '
              'to=${packet.toUserId} route=${decision.type.name}');
          return false;
        }
        Logger.info(
            '[HOP][MeshHandler] $myUserId | ${packet.msgId} | SENT | '
            'to=${packet.toUserId} route=${decision.type.name} hop=${packet.hopCount}');
        return true;

      case RouteType.store:
        Logger.info(
            '[DTN][MeshHandler] $myUserId | ${packet.msgId} | NO_ROUTE_BUFFERED | '
            'to=${packet.toUserId}');
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
        Logger.info(
            '[MeshHandler] ↗️ Forwarded ${packet.msgId} hop=${packet.hopCount}');
        return true;

      case RouteType.store:
        await DtnQueue.enqueue(packet);
        return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Local delivery
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _deliverToSelf(MessagePacket packet) async {
    Logger.info(
        '[MeshHandler] 📨 Delivering ${packet.msgId} from ${packet.fromUserId}');

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
