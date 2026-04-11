import 'package:hive/hive.dart';

part 'known_contact_model.g.dart';

/// How a contact was added to the contact book.
enum ContactAddedVia {
  /// Discovered in-range via BLE or WiFi Direct scan.
  discovery,

  /// Added via Firebase UID/username lookup (not yet implemented).
  firebase,
}

/// Represents a permanently saved OffLink contact.
///
/// Contacts persist across app restarts and are never auto-removed due to
/// going out of range. Only explicit user deletion removes a contact.
///
/// Known contacts allow users to:
///   - Open a chat with any previously seen peer, even when offline
///   - Queue messages for offline peers via the store-and-forward system
///   - See which peers have been seen recently vs long ago
///   - See live presence status (in-range / out-of-range)
@HiveType(typeId: 3)
class KnownContact extends HiveObject {
  /// The peer's persistent UUID (primary identifier, never a MAC address).
  @HiveField(0)
  String peerId;

  /// Human-readable display name as advertised via BLE.
  @HiveField(1)
  String displayName;

  /// BLE / Wi-Fi MAC address (used only for native BLE operations, nullable).
  @HiveField(2)
  String? deviceAddress;

  /// Last time this peer was seen via BLE discovery or presence scan.
  @HiveField(3)
  DateTime lastSeen;

  /// How this contact was added: 'discovery' or 'firebase'.
  @HiveField(4, defaultValue: 'discovery')
  String addedVia;

  /// Optional avatar hash for profile image matching (future use).
  @HiveField(5)
  String? avatarHash;

  KnownContact({
    required this.peerId,
    required this.displayName,
    this.deviceAddress,
    required this.lastSeen,
    this.addedVia = 'discovery',
    this.avatarHash,
  });

  /// Convenience getter for [ContactAddedVia] enum.
  ContactAddedVia get addedViaEnum =>
      addedVia == 'firebase' ? ContactAddedVia.firebase : ContactAddedVia.discovery;

  KnownContact copyWith({
    String? peerId,
    String? displayName,
    String? deviceAddress,
    DateTime? lastSeen,
    String? addedVia,
    String? avatarHash,
  }) {
    return KnownContact(
      peerId: peerId ?? this.peerId,
      displayName: displayName ?? this.displayName,
      deviceAddress: deviceAddress ?? this.deviceAddress,
      lastSeen: lastSeen ?? this.lastSeen,
      addedVia: addedVia ?? this.addedVia,
      avatarHash: avatarHash ?? this.avatarHash,
    );
  }

  @override
  String toString() =>
      'KnownContact(peerId: $peerId, displayName: $displayName, '
      'addedVia: $addedVia, lastSeen: $lastSeen)';
}
