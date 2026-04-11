import 'dart:async';
import 'routing_engine.dart';

/// Tracks peers that are currently reachable by this device.
///
/// Both BLE discovery and Wi-Fi Direct connections call [addPeer] when a
/// peer is found, and [removePeer] when the connection is lost.
///
/// [onPeerAdded] is an optional callback injected by [ConnectionManager] so
/// that a route advertisement is sent whenever a new peer appears — without
/// creating a circular import between [PeerDiscovery] and [MeshHandler].
class PeerDiscovery {
  static final PeerDiscovery instance = PeerDiscovery._();
  PeerDiscovery._();

  final Map<String, PeerInfo> _peers = {};
  final _controller =
      StreamController<Map<String, PeerInfo>>.broadcast();

  /// Fires whenever the peer map changes (peer added or removed).
  Stream<Map<String, PeerInfo>> get peerStream => _controller.stream;

  /// Snapshot of currently reachable peers.
  Map<String, PeerInfo> get currentPeers => Map.unmodifiable(_peers);

  /// Called by [ConnectionManager] after initialising [MeshHandler].
  /// Receives every newly added peer so a route advertisement can be sent.
  void Function(PeerInfo peer)? onPeerAdded;

  /// Register a newly reachable peer. Triggers [onPeerAdded] callback.
  void addPeer(PeerInfo peer) {
    _peers[peer.userId] = peer;
    _controller.add(currentPeers);
    onPeerAdded?.call(peer);
  }

  /// Remove a peer that is no longer reachable (disconnect / timeout).
  void removePeer(String userId) {
    if (_peers.remove(userId) != null) {
      _controller.add(currentPeers);
    }
  }

  void dispose() => _controller.close();
}
