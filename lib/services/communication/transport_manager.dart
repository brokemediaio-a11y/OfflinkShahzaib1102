import 'dart:async';
import 'dart:typed_data';
import '../../models/peer_connection_model.dart';
import '../../models/device_model.dart';
import '../../utils/logger.dart';
import 'bluetooth_service.dart';
import 'ble_peripheral_service.dart';
import 'classic_bluetooth_service.dart';
import 'wifi_direct_service.dart';

/// Manages transport-level connections and byte transmission
/// 
/// This layer is responsible for:
/// - Managing neighbor connections (Map<String, PeerConnection>)
/// - Sending raw bytes to specific peers or broadcasting
/// - Abstracting transport details from upper layers
/// 
/// IMPORTANT: Currently maintains single-connection behavior for stability
/// Structure supports multiple connections for future expansion
class TransportManager {
  static final TransportManager _instance = TransportManager._internal();
  factory TransportManager() => _instance;
  TransportManager._internal();

  /// Map of active peer connections (peerId -> PeerConnection)
  /// Currently limited to one connection, but structured for multiple
  final Map<String, PeerConnection> _neighbors = {};

  /// Transport service instances
  final BluetoothService _bluetoothService = BluetoothService();
  final BlePeripheralService _blePeripheralService = BlePeripheralService();
  final ClassicBluetoothService _classicBluetoothService = ClassicBluetoothService();
  final WifiDirectService _wifiDirectService = WifiDirectService();

  /// Stream controller for incoming raw bytes
  final _incomingBytesController = StreamController<Uint8List>.broadcast();

  /// Stream of incoming raw bytes from any transport
  Stream<Uint8List> get incomingBytes => _incomingBytesController.stream;

  /// Add a neighbor connection
  /// 
  /// For now, this replaces any existing connection (single connection mode)
  /// In future, this will add to the neighbor map (multi-connection mode)
  void addNeighbor(PeerConnection peer) {
    Logger.info('TransportManager: Adding neighbor ${peer.peerId} (${peer.transportType}, ${peer.role})');
    
    // CURRENT BEHAVIOR: Single connection - clear existing neighbors
    // FUTURE: Support multiple simultaneous connections
    if (_neighbors.isNotEmpty) {
      Logger.info('TransportManager: Replacing existing connection (single-connection mode)');
      _neighbors.clear();
    }

    _neighbors[peer.peerId] = peer;
    Logger.info('TransportManager: Now have ${_neighbors.length} neighbor(s)');
  }

  /// Remove a neighbor connection
  void removeNeighbor(String peerId) {
    final removed = _neighbors.remove(peerId);
    if (removed != null) {
      Logger.info('TransportManager: Removed neighbor $peerId');
    }
  }

  /// Get all current neighbors
  List<PeerConnection> getNeighbors() {
    return _neighbors.values.toList();
  }

  /// Get a specific neighbor by ID
  PeerConnection? getNeighbor(String peerId) {
    return _neighbors[peerId];
  }

  /// Check if we have any active neighbors
  bool hasNeighbors() {
    return _neighbors.isNotEmpty;
  }

  /// Get the primary neighbor (for single-connection mode)
  PeerConnection? getPrimaryNeighbor() {
    if (_neighbors.isEmpty) return null;
    return _neighbors.values.first;
  }

  /// Send raw bytes to a specific peer
  /// 
  /// Returns true if sent successfully
  Future<bool> sendToPeer(String peerId, Uint8List data) async {
    try {
      final peer = _neighbors[peerId];
      if (peer == null) {
        Logger.error('TransportManager: No neighbor found with ID $peerId');
        return false;
      }

      Logger.debug('TransportManager: Sending ${data.length} bytes to peer $peerId via ${peer.transportType}');

      // Route to appropriate transport based on peer's transport type
      switch (peer.transportType) {
        case TransportType.ble:
          return await _sendViaBle(peer, data);
        
        case TransportType.classicBluetooth:
          return await _sendViaClassicBluetooth(peer, data);
        
        case TransportType.wifiDirect:
          return await _sendViaWifiDirect(peer, data);
      }
    } catch (e, stackTrace) {
      Logger.error('TransportManager: Error sending to peer $peerId', e, stackTrace);
      return false;
    }
  }

  /// Broadcast raw bytes to all neighbors
  /// 
  /// Returns the number of successful sends
  /// Currently sends to single neighbor, but structured for multiple
  Future<int> broadcastToAllPeers(Uint8List data) async {
    if (_neighbors.isEmpty) {
      Logger.warning('TransportManager: No neighbors to broadcast to');
      return 0;
    }

    Logger.info('TransportManager: Broadcasting ${data.length} bytes to ${_neighbors.length} neighbor(s)');

    int successCount = 0;
    for (final peer in _neighbors.values) {
      final success = await sendToPeer(peer.peerId, data);
      if (success) successCount++;
    }

    Logger.info('TransportManager: Broadcast successful to $successCount/${_neighbors.length} neighbors');
    return successCount;
  }

  /// Send data via BLE (central or peripheral mode)
  Future<bool> _sendViaBle(PeerConnection peer, Uint8List data) async {
    try {
      // Convert bytes to string (current BLE services expect strings)
      // TODO: Update BLE services to handle raw bytes
      final message = String.fromCharCodes(data);

      if (peer.role == ConnectionRole.central) {
        // We are central - send via BluetoothService
        return await _bluetoothService.sendMessage(message);
      } else {
        // We are peripheral - send via BlePeripheralService
        return await _blePeripheralService.sendMessage(message);
      }
    } catch (e) {
      Logger.error('TransportManager: Error sending via BLE', e);
      return false;
    }
  }

  /// Send data via Classic Bluetooth
  Future<bool> _sendViaClassicBluetooth(PeerConnection peer, Uint8List data) async {
    try {
      // Convert bytes to string (current service expects strings)
      final message = String.fromCharCodes(data);
      return await _classicBluetoothService.sendMessage(message);
    } catch (e) {
      Logger.error('TransportManager: Error sending via Classic Bluetooth', e);
      return false;
    }
  }

  /// Send data via WiFi Direct
  Future<bool> _sendViaWifiDirect(PeerConnection peer, Uint8List data) async {
    try {
      // Convert bytes to string (current service expects strings)
      final message = String.fromCharCodes(data);
      return await _wifiDirectService.sendMessage(message);
    } catch (e) {
      Logger.error('TransportManager: Error sending via WiFi Direct', e);
      return false;
    }
  }

  /// Handle incoming raw bytes from any transport
  void onBytesReceived(Uint8List bytes, {String? fromPeerId}) {
    Logger.debug('TransportManager: Received ${bytes.length} bytes from ${fromPeerId ?? "unknown peer"}');
    
    // Update lastSeen for the peer if known
    if (fromPeerId != null && _neighbors.containsKey(fromPeerId)) {
      _neighbors[fromPeerId] = _neighbors[fromPeerId]!.updateLastSeen();
    }

    _incomingBytesController.add(bytes);
  }

  /// Clear all neighbors (disconnect all)
  void clearNeighbors() {
    Logger.info('TransportManager: Clearing all ${_neighbors.length} neighbor(s)');
    _neighbors.clear();
  }

  /// Get statistics about the transport manager
  Map<String, dynamic> getStatistics() {
    return {
      'neighborCount': _neighbors.length,
      'neighbors': _neighbors.values.map((p) => {
        'peerId': p.peerId,
        'transport': p.transportType.name,
        'role': p.role.name,
        'lastSeen': p.lastSeen.toIso8601String(),
      }).toList(),
    };
  }

  /// Create a PeerConnection from a DeviceModel and connection details
  PeerConnection createPeerConnection({
    required DeviceModel device,
    required TransportType transportType,
    required ConnectionRole role,
    Object? connectionObject,
  }) {
    return PeerConnection(
      peerId: device.id,
      transportType: transportType,
      lastSeen: DateTime.now(),
      role: role,
      connectionObject: connectionObject,
    );
  }

  /// Dispose resources
  void dispose() {
    _incomingBytesController.close();
    _neighbors.clear();
  }
}
