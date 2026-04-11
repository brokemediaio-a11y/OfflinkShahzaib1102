import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/presence_service.dart';

/// State for the presence tracking system.
class PresenceState {
  /// Map of deviceUuid → ContactPresence for all tracked contacts.
  final Map<String, ContactPresence> presenceMap;

  /// Whether the presence tracking service is active.
  final bool isTracking;

  const PresenceState({
    this.presenceMap = const {},
    this.isTracking = false,
  });

  PresenceState copyWith({
    Map<String, ContactPresence>? presenceMap,
    bool? isTracking,
  }) {
    return PresenceState(
      presenceMap: presenceMap ?? this.presenceMap,
      isTracking: isTracking ?? this.isTracking,
    );
  }

  /// Check if a specific contact is in range.
  bool isInRange(String deviceUuid) =>
      presenceMap[deviceUuid]?.inRange ?? false;

  /// Get RSSI signal bars (0-4) for a contact.
  int signalBars(String deviceUuid) =>
      presenceMap[deviceUuid]?.signalBars ?? 0;
}

/// Riverpod provider for live presence tracking state.
///
/// Listens to [PresenceService] and updates the UI reactively when
/// contacts come in/out of range.
class PresenceNotifier extends StateNotifier<PresenceState> {
  final PresenceService _presenceService;
  StreamSubscription<ContactPresence>? _subscription;

  PresenceNotifier(this._presenceService) : super(const PresenceState()) {
    _subscription = _presenceService.presenceChanges.listen(_onPresenceChange);
  }

  void _onPresenceChange(ContactPresence presence) {
    final newMap = Map<String, ContactPresence>.from(state.presenceMap);
    newMap[presence.deviceUuid] = presence;
    state = state.copyWith(
      presenceMap: newMap,
      isTracking: _presenceService.isTracking,
    );
  }

  /// Start presence tracking for all saved contacts.
  Future<void> startTracking() async {
    await _presenceService.startTracking();
    state = state.copyWith(isTracking: _presenceService.isTracking);
  }

  /// Stop presence tracking.
  Future<void> stopTracking() async {
    await _presenceService.stopTracking();
    state = state.copyWith(
      isTracking: false,
      presenceMap: {},
    );
  }

  /// Refresh the watched contacts list (call after adding/removing contacts).
  Future<void> refreshWatchedContacts() async {
    await _presenceService.updateWatchedContacts();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/// The global presence provider.
final presenceProvider =
    StateNotifierProvider<PresenceNotifier, PresenceState>((ref) {
  return PresenceNotifier(PresenceService.instance);
});
