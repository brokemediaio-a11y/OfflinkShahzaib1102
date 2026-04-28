import 'package:hive_flutter/hive_flutter.dart';
import '../models/device_model.dart';

/// Simulates a 3-device linear topology for desk-testing relay hopping.
///
/// When enabled, RSSI values reported to the connection/relay logic are
/// replaced with mathematically derived values based on each device's
/// position in the lexicographically-sorted set of all visible UUIDs:
///
///   [uuid0] ──── [uuid1] ──── [uuid2]
///
/// Devices that are adjacent (gap == 1) receive NEAR_RSSI (-60 dBm).
/// Devices that are non-adjacent (gap >= 2) receive FAR_RSSI (-96 dBm),
/// which is below the directWifiRssiThreshold (-90 dBm) in ConnectionManager,
/// forcing the relay path instead of a direct connection.
///
/// This means:
///   • uuid0 sees uuid1 as NEAR, uuid2 as FAR  → must hop via uuid1
///   • uuid1 sees uuid0 AND uuid2 as NEAR       → acts as relay
///   • uuid2 sees uuid1 as NEAR, uuid0 as FAR  → must hop via uuid1
///
/// Real RSSI / physical distance is completely ignored while simulation is on.
class HopSimulator {
  static const _boxName = 'device_preferences';
  static const _enabledKey = 'hop_sim_enabled';

  /// Simulated RSSI for an "adjacent" device (clearly connectable).
  static const int nearRssi = -60;

  /// Simulated RSSI for a "non-adjacent" device (below the -90 dBm threshold
  /// in ConnectionManager, so the relay path is chosen instead).
  static const int farRssi = -96;

  static bool _enabled = false;

  /// Whether simulation mode is currently active.
  static bool get isEnabled => _enabled;

  /// Load persisted state from Hive. Call once after DeviceStorage.init().
  static void load() {
    try {
      final box = Hive.box(_boxName);
      _enabled = box.get(_enabledKey, defaultValue: false) as bool;
    } catch (_) {
      _enabled = false;
    }
  }

  /// Enable or disable simulation and persist the choice.
  static Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final box = Hive.box(_boxName);
      await box.put(_enabledKey, value);
    } catch (_) {}
  }

  /// Return a topology description for the debug UI.
  ///
  /// [myId] — this device's UUID.
  /// [peers] — currently visible peer devices.
  static String topologyDescription(String myId, List<DeviceModel> peers) {
    if (peers.isEmpty) return 'No peers visible yet — topology pending.';
    final allIds = [myId, ...peers.map((d) => d.id)]..sort();
    final myPos = allIds.indexOf(myId);
    final lines = <String>[];
    for (final d in peers) {
      final peerPos = allIds.indexOf(d.id);
      final gap = (myPos - peerPos).abs();
      final label = gap == 1 ? 'NEAR ($nearRssi dBm)' : 'FAR  ($farRssi dBm)';
      lines.add('${d.name.isEmpty ? d.id.substring(0, 8) : d.name}  →  $label');
    }
    final role = myPos == 0 || myPos == allIds.length - 1 ? 'ENDPOINT' : 'RELAY';
    return 'My role: $role (pos $myPos)\n${lines.join('\n')}';
  }

  /// Apply simulated RSSI overrides to [peers].
  ///
  /// If simulation is disabled, returns the original list unchanged.
  static List<DeviceModel> apply(String myId, List<DeviceModel> peers) {
    if (!_enabled || peers.isEmpty) return peers;
    final allIds = [myId, ...peers.map((d) => d.id)]..sort();
    final myPos = allIds.indexOf(myId);
    return peers.map((d) {
      final peerPos = allIds.indexOf(d.id);
      final gap = (myPos - peerPos).abs();
      return d.copyWith(rssi: gap == 1 ? nearRssi : farRssi);
    }).toList();
  }
}
