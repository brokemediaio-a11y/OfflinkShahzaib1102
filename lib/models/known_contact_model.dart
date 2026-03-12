import 'package:hive/hive.dart';

part 'known_contact_model.g.dart';

/// Represents a peer that has been previously discovered via BLE.
///
/// Known contacts allow users to:
///   - Open a chat with any previously seen peer, even when offline
///   - Queue messages for offline peers via the store-and-forward system
///   - See which peers have been seen recently vs long ago
@HiveType(typeId: 3)
class KnownContact extends HiveObject {
  /// The peer's persistent UUID (primary identifier, never a MAC address).
  @HiveField(0)
  String peerId;

  /// Human-readable display name as advertised via BLE.
  @HiveField(1)
  String displayName;

  /// BLE / Wi-Fi MAC address (used only for native BLE operations).
  @HiveField(2)
  String? deviceAddress;

  /// Last time this peer was seen via BLE discovery.
  @HiveField(3)
  DateTime lastSeen;

  KnownContact({
    required this.peerId,
    required this.displayName,
    this.deviceAddress,
    required this.lastSeen,
  });

  KnownContact copyWith({
    String? peerId,
    String? displayName,
    String? deviceAddress,
    DateTime? lastSeen,
  }) {
    return KnownContact(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      deviceAddress: deviceAddress ?? this.deviceAddress,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  @override
  String toString() =>
      'KnownContact(peerId: $peerId, displayName: $displayName, '
      'lastSeen: $lastSeen)';
}
