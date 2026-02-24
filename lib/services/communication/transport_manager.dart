import 'dart:async';
import 'dart:typed_data';
import '../../models/peer_connection_model.dart';
import '../../models/device_model.dart';
import '../../utils/logger.dart';
import 'wifi_direct_service.dart';

/// TransportManager — Data Plane routing hub
///
/// Responsibilities:
///   - Maintain the map of active peer connections (peerId → PeerConnection)
///   - Route outgoing bytes to the correct transport service
///   - Expose an incomingBytes stream for the upper routing layer
///   - Abstract all transport details from ConnectionManager and RoutingManager
///
/// Architecture:
///   BLE  → Discovery/Control Plane only.  NOT in the transport map.
///   Wi-Fi Direct → PRIMARY and ONLY data transport for chat messages.
///
/// Future extensibility:
///   - BLE can be re-added as a secondary transport by adding its case back
///     to [sendToPeer] without touching RoutingManager.
///   - Multi-hop forwarding requires no changes to this class.
///   - Transport prioritisation can be added via a PeerConnection.priority field.
class TransportManager {
  static final TransportManager _instance = TransportManager._internal();
  factory TransportManager() => _instance;
  TransportManager._internal();

  // ── Active peer connections ───────────────────────────────────────
  /// peerId → PeerConnection
  final Map<String, PeerConnection> _neighbors = {};

  // ── Transport services ────────────────────────────────────────────
  /// Wi-Fi Direct is the SOLE data transport.
  final WifiDirectService _wifiDirectService = WifiDirectService();

  // ── Incoming bytes stream ─────────────────────────────────────────
  final _incomingBytesController = StreamController<Uint8List>.broadcast();

  /// Raw bytes arriving from any transport (currently Wi-Fi Direct only).
  Stream<Uint8List> get incomingBytes => _incomingBytesController.stream;

  // ═══════════════════════════════════════════════════════════════
  // Neighbor management
  // ═══════════════════════════════════════════════════════════════

  /// Register a new peer connection.
  ///
  /// Maintains single-connection semantics (clears existing peers).
  /// Structured for future multi-connection support.
  void addNeighbor(PeerConnection peer) {
    Logger.info(
        'TransportManager: adding neighbor ${peer.peerId} '
        '(${peer.transportType}, ${peer.role}, '
        'ip=${peer.ipAddress}, socket=${peer.socketActive})');

    // Single-connection mode — clear any previous peer.
    // Future: remove this clear() to support multiple simultaneous connections.
    if (_neighbors.isNotEmpty) {
      Logger.info(
          'TransportManager: replacing existing neighbor (single-connection mode)');
      _neighbors.clear();
    }

    _neighbors[peer.peerId] = peer;
    Logger.info('TransportManager: ${_neighbors.length} neighbor(s) registered');
  }

  /// Remove a peer connection by ID.
  void removeNeighbor(String peerId) {
    final removed = _neighbors.remove(peerId);
    if (removed != null) {
      Logger.info('TransportManager: removed neighbor $peerId');
    }
  }

  /// Update socket-active flag on an existing peer connection.
  void markSocketActive(String peerId, {required bool active}) {
    final peer = _neighbors[peerId];
    if (peer != null) {
      _neighbors[peerId] = peer.withSocketActive(active);
      Logger.info(
          'TransportManager: peer $peerId socketActive → $active');
    }
  }

  List<PeerConnection> getNeighbors() => _neighbors.values.toList();

  PeerConnection? getNeighbor(String peerId) => _neighbors[peerId];

  bool hasNeighbors() => _neighbors.isNotEmpty;

  /// Returns the first (and typically only) active peer.
  PeerConnection? getPrimaryNeighbor() {
    if (_neighbors.isEmpty) return null;
    return _neighbors.values.first;
  }

  void clearNeighbors() {
    Logger.info('TransportManager: clearing all ${_neighbors.length} neighbor(s)');
    _neighbors.clear();
  }

  // ═══════════════════════════════════════════════════════════════
  // Outgoing data
  // ═══════════════════════════════════════════════════════════════

  /// Send raw bytes to a specific peer.
  ///
  /// Routes exclusively to Wi-Fi Direct.
  /// BLE is NOT used for data delivery — it is the control/discovery plane.
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    try {
      final peer = _neighbors[peerId];
      if (peer == null) {
        Logger.error('TransportManager: no neighbor found with id $peerId');
        return false;
      }

      Logger.debug(
          'TransportManager: sending ${data.length} bytes to $peerId '
          'via ${peer.transportType}');

      switch (peer.transportType) {
        case TransportType.wifiDirect:
          return await _sendViaWifiDirect(data);

        case TransportType.ble:
          // BLE is discovery-only in the dual-radio architecture.
          // Reject data-plane sends over BLE to enforce clean separation.
          Logger.error(
              'TransportManager: data send via BLE is not permitted — '
              'BLE is the discovery/control plane only. '
              'Ensure Wi-Fi Direct is connected before sending messages.');
          return false;

        case TransportType.classicBluetooth:
          // Classic Bluetooth is kept for backward compat but is not the
          // primary transport in the dual-radio architecture.
          Logger.warning(
              'TransportManager: Classic Bluetooth data send is deprecated. '
              'Use Wi-Fi Direct as primary transport.');
          return false;
      }
    } catch (e, st) {
      Logger.error('TransportManager: sendToPeer error for $peerId', e, st);
      return false;
    }
  }

  /// Broadcast raw bytes to all registered neighbors.
  ///
  /// Returns the count of successful sends.
  Future<int> broadcastToAllPeers(Uint8List data) async {
    if (_neighbors.isEmpty) {
      Logger.warning('TransportManager: no neighbors to broadcast to');
      return 0;
    }

    Logger.info(
        'TransportManager: broadcasting ${data.length} bytes '
        'to ${_neighbors.length} neighbor(s)');

    int successCount = 0;
    for (final peer in _neighbors.values) {
      if (await sendToPeer(peer.peerId, data)) successCount++;
    }

    Logger.info(
        'TransportManager: broadcast success $successCount/${_neighbors.length}');
    return successCount;
  }

  // ═══════════════════════════════════════════════════════════════
  // Incoming data
  // ═══════════════════════════════════════════════════════════════

  /// Called by ConnectionManager when bytes arrive from any transport.
  ///
  /// Updates lastSeen for the known peer and emits on [incomingBytes].
  void onBytesReceived(Uint8List bytes, {String? fromPeerId}) {
    Logger.debug(
        'TransportManager: received ${bytes.length} bytes '
        'from ${fromPeerId ?? "unknown"}');

    if (fromPeerId != null && _neighbors.containsKey(fromPeerId)) {
      _neighbors[fromPeerId] = _neighbors[fromPeerId]!.updateLastSeen();
    }

    _incomingBytesController.add(bytes);
  }

  // ═══════════════════════════════════════════════════════════════
  // Private transport methods
  // ═══════════════════════════════════════════════════════════════

  Future<bool> _sendViaWifiDirect(Uint8List data) async {
    try {
      final message = String.fromCharCodes(data);
      return await _wifiDirectService.sendMessage(message);
    } catch (e) {
      Logger.error('TransportManager: Wi-Fi Direct send error', e);
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // Factory helpers
  // ═══════════════════════════════════════════════════════════════

  /// Build a [PeerConnection] from a [DeviceModel] and transport details.
  PeerConnection createPeerConnection({
    required DeviceModel device,
    required TransportType transportType,
    required ConnectionRole role,
    Object? connectionObject,
    String? ipAddress,
    bool socketActive = false,
  }) {
    return PeerConnection(
      peerId: device.id,
      transportType: transportType,
      lastSeen: DateTime.now(),
      role: role,
      connectionObject: connectionObject,
      ipAddress: ipAddress,
      socketActive: socketActive,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // Statistics / diagnostics
  // ═══════════════════════════════════════════════════════════════

  Map<String, dynamic> getStatistics() {
    return {
      'neighborCount': _neighbors.length,
      'neighbors': _neighbors.values
          .map((p) => {
                'peerId': p.peerId,
                'transport': p.transportType.name,
                'role': p.role.name,
                'socketActive': p.socketActive,
                'ipAddress': p.ipAddress,
                'lastSeen': p.lastSeen.toIso8601String(),
              })
          .toList(),
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // Lifecycle
  // ═══════════════════════════════════════════════════════════════

  void dispose() {
    _incomingBytesController.close();
    _neighbors.clear();
  }
}
