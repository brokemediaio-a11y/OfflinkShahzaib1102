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
    Logger.info('[DtnRetryLoop] Started (30 s interval)');
  }

  /// Stop the retry loop.
  void stop() {
    _timer?.cancel();
    _timer = null;
    Logger.info('[DtnRetryLoop] Stopped');
  }

  Future<void> _tick() async {
    try {
      final peers = PeerDiscovery.instance.currentPeers;
      if (peers.isEmpty) return; // nothing to do without peers

      final pending = await DtnQueue.getPendingPackets();
      if (pending.isEmpty) return;

      Logger.info(
          '[DtnRetryLoop] Retrying ${pending.length} buffered packet(s) '
          'with ${peers.length} peer(s) in range');

      for (final packet in pending) {
        final sent = await meshHandler.forward(packet, peers);
        await DtnQueue.recordAttempt(packet.msgId, delivered: sent);
      }

      // Housekeeping
      await DtnQueue.purgeExpired();
      await RoutingEngine.evictStaleRoutes();
      await SeenCache.evictExpired();
    } catch (e) {
      Logger.error('[DtnRetryLoop] Error during tick', e);
    }
  }
}
