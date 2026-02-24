/// Model representing a connection to a neighbouring peer in the network.
///
/// Transport-agnostic: the routing layer never inspects transport details.
/// The transport layer uses this model to route bytes to the right service.
class PeerConnection {
  /// Unique identifier for the peer (device UUID).
  final String peerId;

  /// The transport method used for this connection.
  final TransportType transportType;

  /// When this connection was last active.
  final DateTime lastSeen;

  /// The role we play in this connection (transport-level detail).
  /// For Wi-Fi Direct: [ConnectionRole.peripheral] = Group Owner,
  ///                   [ConnectionRole.central]    = Client.
  final ConnectionRole role;

  /// The underlying connection object (BluetoothDevice, Socket, etc.).
  /// Stored as [Object?] to avoid coupling with specific transport types.
  final Object? connectionObject;

  // ── Wi-Fi Direct specific fields ─────────────────────────────────

  /// IP address relevant to this connection.
  ///   Group Owner: 192.168.49.1 (fixed on Android Wi-Fi Direct)
  ///   Client: the DHCP-assigned IP it received from the GO
  final String? ipAddress;

  /// True once the TCP socket over Wi-Fi Direct is established and
  /// ready for bidirectional message exchange.
  final bool socketActive;

  PeerConnection({
    required this.peerId,
    required this.transportType,
    required this.lastSeen,
    required this.role,
    this.connectionObject,
    this.ipAddress,
    this.socketActive = false,
  });

  /// Create a copy with selectively overridden fields.
  PeerConnection copyWith({
    String? peerId,
    TransportType? transportType,
    DateTime? lastSeen,
    ConnectionRole? role,
    Object? connectionObject,
    String? ipAddress,
    bool? socketActive,
  }) {
    return PeerConnection(
      peerId: peerId ?? this.peerId,
      transportType: transportType ?? this.transportType,
      lastSeen: lastSeen ?? this.lastSeen,
      role: role ?? this.role,
      connectionObject: connectionObject ?? this.connectionObject,
      ipAddress: ipAddress ?? this.ipAddress,
      socketActive: socketActive ?? this.socketActive,
    );
  }

  /// Update the lastSeen timestamp (call on every received message).
  PeerConnection updateLastSeen() => copyWith(lastSeen: DateTime.now());

  /// Mark socket as active/inactive.
  PeerConnection withSocketActive(bool active) =>
      copyWith(socketActive: active);

  /// True when this is a Wi-Fi Direct Group Owner connection.
  bool get isWifiGroupOwner =>
      transportType == TransportType.wifiDirect &&
      role == ConnectionRole.peripheral;

  /// True when this is a Wi-Fi Direct client connection.
  bool get isWifiClient =>
      transportType == TransportType.wifiDirect &&
      role == ConnectionRole.central;

  @override
  String toString() {
    return 'PeerConnection('
        'peerId: $peerId, '
        'transport: $transportType, '
        'role: $role, '
        'socketActive: $socketActive, '
        'ipAddress: $ipAddress, '
        'lastSeen: $lastSeen)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PeerConnection && other.peerId == peerId;
  }

  @override
  int get hashCode => peerId.hashCode;
}

// ── Transport type enum ───────────────────────────────────────────────────────

/// Identifies the radio/protocol used for a peer connection.
///
/// Designed for future extensibility:
///   - [ble] can be reintroduced as a secondary/fallback transport later.
///   - New transports (Bluetooth Mesh, LoRa, etc.) can be added without
///     breaking existing logic.
enum TransportType {
  /// Bluetooth Low Energy — discovery only; NOT used for chat payload.
  /// Kept in enum for future extensibility (secondary transport).
  ble,

  /// Classic Bluetooth RFCOMM — legacy transport, kept for compatibility.
  classicBluetooth,

  /// Wi-Fi Direct (IEEE 802.11) — PRIMARY data transport for chat messages.
  wifiDirect,
}

// ── Connection role enum ──────────────────────────────────────────────────────

/// Role we play in a connection (transport-level detail).
///
/// NOT exposed at the application/routing layer — all peers are equal
/// from the routing perspective.
///
/// Wi-Fi Direct mapping:
///   [peripheral] → Wi-Fi Direct Group Owner (GO)
///   [central]    → Wi-Fi Direct Client
enum ConnectionRole {
  /// We initiated the connection — BLE Central, Wi-Fi Direct Client.
  central,

  /// They initiated / we are hosting — BLE Peripheral, Wi-Fi Direct Group Owner.
  peripheral,
}
