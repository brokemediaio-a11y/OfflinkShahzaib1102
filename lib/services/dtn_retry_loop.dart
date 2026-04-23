import 'dart:async';
import '../utils/logger.dart';
import 'dtn_queue.dart';
import 'routing_engine.dart';
import 'seen_cache.dart';
import 'mesh_handler.dart';
import 'peer_discovery.dart';

/// Background retry loop for the DTN store-and-forward queue.
///
/// Runs every 30 seconds. When peers are in range, attempts to deliver
/// buffered [MessagePacket]s from [DtnQueue]. Also performs periodic
/// housekeeping (purge expired entries, evict stale routes / seen cache).
class DtnRetryLoop {
  final MeshHandler meshHandler;
  Timer? _timer;

  DtnRetryLoop({required this.meshHandler});

  /// Start the retry loop. Safe to call multiple times (idempotent).
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
    Logger.dtnLog('⏱ RetryLoop started — 30 s interval');
  }

  /// Stop the retry loop.
  void stop() {
    _timer?.cancel();
    _timer = null;
    Logger.dtnLog('⏹ RetryLoop stopped');
  }

  /// Public for debug panel — normally called by the internal timer only.
  Future<void> tick() => _tick();

  Future<void> _tick() async {
    try {
      // ── Housekeeping runs ALWAYS, regardless of peer presence ──
      await DtnQueue.purgeExpired();
      await RoutingEngine.evictStaleRoutes();
      await SeenCache.evictExpired();

      // ── Delivery retries only when peers are available ──
      final peers = PeerDiscovery.instance.currentPeers;
      if (peers.isEmpty) return;

      final pending = await DtnQueue.getPendingPackets();
      if (pending.isEmpty) return;

      Logger.dtnLog(
          'RETRY | ${pending.length} packet(s) queued | ${peers.length} peer(s) visible');

      for (final packet in pending) {
        final sent = await meshHandler.forward(packet, peers);
        if (packet.toUserId == '*' && packet.type == 'broadcast') {
          if (sent) {
            await DtnQueue.recordBroadcastSent(packet.msgId);
          } else {
            await DtnQueue.recordAttempt(packet.msgId, delivered: false);
          }
          continue;
        }

        // A unicast relay handoff is not final delivery. Keep the packet in
        // the queue until the destination ACK removes it.
        if (sent) {
          await DtnQueue.recordHandoff(packet.msgId);
        } else {
          await DtnQueue.recordAttempt(packet.msgId, delivered: false);
        }
      }
    } catch (e) {
      Logger.error('RetryLoop tick error', e, null, Logger.dtn);
    }
  }
}
