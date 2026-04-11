import 'dart:async';
import 'package:flutter/services.dart';
import '../utils/logger.dart';
import 'storage/known_contacts_storage.dart';

/// Presence state for a single contact.
class ContactPresence {
  final String deviceUuid;
  final bool inRange;
  final int rssi;
  final DateTime lastUpdated;

  const ContactPresence({
    required this.deviceUuid,
    required this.inRange,
    required this.rssi,
    required this.lastUpdated,
  });

  /// Signal quality score (0-4 bars) based on RSSI.
  /// Feature 5: RSSI-Based Quality Scoring.
  int get signalBars {
    if (!inRange || rssi == 0) return 0;
    if (rssi >= -50) return 4;  // Excellent
    if (rssi >= -60) return 3;  // Good
    if (rssi >= -70) return 2;  // Fair
    if (rssi >= -80) return 1;  // Weak
    return 0;                    // Very weak / out of range
  }
}

/// Dart-side service that bridges to the native PresenceTracker foreground service.
///
/// Manages the lifecycle of BLE presence scanning and exposes a stream of
/// presence change events for the UI layer (PresenceProvider).
class PresenceService {
  static const _methodChannel = MethodChannel('com.offlink.presence');
  static const _eventChannel = EventChannel('com.offlink.presence/events');

  static PresenceService? _instance;
  static PresenceService get instance => _instance ??= PresenceService._();
  PresenceService._();

  StreamSubscription? _eventSubscription;
  bool _isTracking = false;

  /// Current presence state per contact UUID.
  final Map<String, ContactPresence> _presenceMap = {};

  /// Stream of presence change events.
  final _presenceController = StreamController<ContactPresence>.broadcast();
  Stream<ContactPresence> get presenceChanges => _presenceController.stream;

  /// Get current presence for a specific contact.
  ContactPresence? getPresence(String deviceUuid) => _presenceMap[deviceUuid];

  /// Whether a contact is currently in range.
  bool isInRange(String deviceUuid) =>
      _presenceMap[deviceUuid]?.inRange ?? false;

  /// Whether presence tracking is active.
  bool get isTracking => _isTracking;

  /// Start the presence tracking foreground service.
  ///
  /// Reads all saved contacts from [KnownContactsStorage] and sends their
  /// UUIDs to the native PresenceTracker to watch for.
  Future<void> startTracking() async {
    if (_isTracking) return;

    try {
      final contacts = KnownContactsStorage.getAllContacts();
      final uuids = contacts.map((c) => c.peerId).toList();

      if (uuids.isEmpty) {
        Logger.info('[PresenceService] No saved contacts — skipping presence start');
        return;
      }

      // Start listening to native events
      _eventSubscription?.cancel();
      _eventSubscription = _eventChannel
          .receiveBroadcastStream()
          .listen(_handleNativeEvent, onError: _handleError);

      // Start the native foreground service
      await _methodChannel.invokeMethod('startPresenceTracking', {
        'contactUuids': uuids,
      });

      _isTracking = true;
      Logger.info('[PresenceService] Started tracking ${uuids.length} contact(s)');
    } catch (e) {
      Logger.error('[PresenceService] Error starting tracking', e);
    }
  }

  /// Stop the presence tracking foreground service.
  Future<void> stopTracking() async {
    if (!_isTracking) return;

    try {
      await _methodChannel.invokeMethod('stopPresenceTracking');
      _eventSubscription?.cancel();
      _eventSubscription = null;
      _isTracking = false;
      _presenceMap.clear();
      Logger.info('[PresenceService] Stopped tracking');
    } catch (e) {
      Logger.error('[PresenceService] Error stopping tracking', e);
    }
  }

  /// Update the list of watched contacts (e.g. after adding/removing a contact).
  Future<void> updateWatchedContacts() async {
    if (!_isTracking) return;

    try {
      final contacts = KnownContactsStorage.getAllContacts();
      final uuids = contacts.map((c) => c.peerId).toList();
      await _methodChannel.invokeMethod('updateWatchedContacts', {
        'contactUuids': uuids,
      });
      Logger.info('[PresenceService] Updated watched contacts: ${uuids.length}');
    } catch (e) {
      Logger.error('[PresenceService] Error updating watched contacts', e);
    }
  }

  void _handleNativeEvent(dynamic event) {
    try {
      final map = Map<String, dynamic>.from(event as Map);
      final type = map['type'] as String;
      final deviceUuid = map['deviceUuid'] as String;
      final inRange = map['inRange'] as bool;
      final rssi = map['rssi'] as int? ?? 0;

      final presence = ContactPresence(
        deviceUuid: deviceUuid,
        inRange: inRange,
        rssi: rssi,
        lastUpdated: DateTime.now(),
      );

      _presenceMap[deviceUuid] = presence;
      _presenceController.add(presence);

      if (type == 'presence_change') {
        Logger.info(
            '[PresenceService] ${inRange ? "IN_RANGE" : "OUT_OF_RANGE"} '
            '$deviceUuid (RSSI: $rssi)');
      }
    } catch (e) {
      Logger.error('[PresenceService] Error handling native event', e);
    }
  }

  void _handleError(dynamic error) {
    Logger.error('[PresenceService] EventChannel error: $error');
  }

  void dispose() {
    _eventSubscription?.cancel();
    _presenceController.close();
  }
}
