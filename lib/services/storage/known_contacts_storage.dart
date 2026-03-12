import 'package:hive_flutter/hive_flutter.dart';
import '../../models/known_contact_model.dart';
import '../../utils/logger.dart';

/// Persistent storage for previously discovered OffLink peers.
///
/// Peers are saved here the first time they are discovered via BLE.
/// This enables:
///   - Showing contact list even when no devices are in range
///   - Opening chats and queuing messages for offline peers
///   - Displaying "last seen" timestamps
class KnownContactsStorage {
  static const String _boxName = 'known_contacts';
  static Box<KnownContact>? _box;

  static Future<void> init() async {
    try {
      _box = await Hive.openBox<KnownContact>(_boxName);
      Logger.info(
          'KnownContactsStorage: initialized with ${_box!.length} known contacts');
    } catch (e) {
      Logger.error('KnownContactsStorage: failed to initialize', e);
      rethrow;
    }
  }

  // ── Save / Update ────────────────────────────────────────────────

  /// Save or update a known contact.
  ///
  /// If the peer already exists, updates displayName, deviceAddress, and lastSeen.
  /// If new, creates a new entry.
  static Future<void> saveContact({
    required String peerId,
    required String displayName,
    String? deviceAddress,
  }) async {
    try {
      if (_box == null) return;

      // Skip invalid IDs
      if (peerId.isEmpty || peerId == '__uuid_pending__') return;

      final existing = _box!.get(peerId);
      if (existing != null) {
        // Update existing contact
        existing.displayName = displayName;
        if (deviceAddress != null && deviceAddress.isNotEmpty) {
          existing.deviceAddress = deviceAddress;
        }
        existing.lastSeen = DateTime.now();
        await existing.save();
        Logger.debug('KnownContactsStorage: updated contact $peerId ($displayName)');
      } else {
        // Create new contact
        final contact = KnownContact(
          peerId: peerId,
          displayName: displayName,
          deviceAddress: deviceAddress,
          lastSeen: DateTime.now(),
        );
        await _box!.put(peerId, contact);
        Logger.info(
            'KnownContactsStorage: ✨ new contact saved — $peerId ($displayName)');
      }
    } catch (e) {
      Logger.error('KnownContactsStorage: error saving contact $peerId', e);
    }
  }

  // ── Query ────────────────────────────────────────────────────────

  static KnownContact? getContact(String peerId) {
    return _box?.get(peerId);
  }

  static List<KnownContact> getAllContacts() {
    return _box?.values.toList() ?? [];
  }

  static bool hasContact(String peerId) {
    return _box?.containsKey(peerId) ?? false;
  }

  // ── Update ───────────────────────────────────────────────────────

  static Future<void> updateLastSeen(String peerId) async {
    try {
      final contact = _box?.get(peerId);
      if (contact != null) {
        contact.lastSeen = DateTime.now();
        await contact.save();
      }
    } catch (e) {
      Logger.error(
          'KnownContactsStorage: error updating lastSeen for $peerId', e);
    }
  }

  // ── Stats ────────────────────────────────────────────────────────

  static int getContactCount() => _box?.length ?? 0;

  static Future<void> clearAll() async {
    await _box?.clear();
    Logger.info('KnownContactsStorage: all contacts cleared');
  }
}
