/// Model representing a connection to a neighboring peer in the mesh network
/// This abstraction allows for multiple simultaneous connections and different transport types
class PeerConnection {
  /// Unique identifier for the peer (device UUID)
  final String peerId;

  /// The transport method used for this connection
  final TransportType transportType;

  /// When this connection was last active
  final DateTime lastSeen;

  /// The role we play in this connection (central or peripheral)
  /// This is a transport-level detail, not visible at the application layer
  final ConnectionRole role;

  /// The underlying connection object (BluetoothDevice, socket, etc.)
  /// Stored as dynamic to avoid coupling with specific transport implementations
  final Object? connectionObject;

  PeerConnection({
    required this.peerId,
    required this.transportType,
    required this.lastSeen,
    required this.role,
    this.connectionObject,
  });

  /// Create a copy with updated fields
  PeerConnection copyWith({
    String? peerId,
    TransportType? transportType,
    DateTime? lastSeen,
    ConnectionRole? role,
    Object? connectionObject,
  }) {
    return PeerConnection(
      peerId: peerId ?? this.peerId,
      transportType: transportType ?? this.transportType,
      lastSeen: lastSeen ?? this.lastSeen,
      role: role ?? this.role,
      connectionObject: connectionObject ?? this.connectionObject,
    );
  }

  /// Update the lastSeen timestamp
  PeerConnection updateLastSeen() {
    return copyWith(lastSeen: DateTime.now());
  }

  @override
  String toString() {
    return 'PeerConnection(peerId: $peerId, transport: $transportType, role: $role, lastSeen: $lastSeen)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PeerConnection && other.peerId == peerId;
  }

  @override
  int get hashCode => peerId.hashCode;
}

/// Transport method used for a peer connection
enum TransportType {
  /// Bluetooth Low Energy
  ble,

  /// Classic Bluetooth (RFCOMM)
  classicBluetooth,

  /// WiFi Direct
  wifiDirect,
}

/// Role we play in a connection (transport-level detail)
/// This is NOT exposed at the application layer - all peers are equal in the mesh
enum ConnectionRole {
  /// We initiated the connection (BLE central, WiFi client, etc.)
  central,

  /// They initiated the connection (BLE peripheral, WiFi host, etc.)
  peripheral,
}
