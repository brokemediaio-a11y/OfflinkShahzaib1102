import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import '../../models/device_model.dart';
import '../../core/constants.dart';
import '../../utils/logger.dart';
import '../storage/scan_log_storage.dart';
import '../storage/device_storage.dart';
import '../storage/known_contacts_storage.dart';

/// BleDiscoveryService — Control Plane (Discovery Only)
///
/// Responsibilities:
///   - Scan for nearby Offlink peers via BLE
///   - Extract Device UUID and Username from manufacturer data
///   - Report RSSI per peer
///   - Notify ConnectionManager when a peer is discovered/updated
///
/// BLE must NOT:
///   - Send chat messages
///   - Handle message payload transmission
///   - Maintain chat connection state
///
/// This is the refactored successor to BluetoothService.
/// All GATT connection, characteristic write/notify and message
/// transport logic has been removed.
class BleDiscoveryService {
  static final BleDiscoveryService _instance = BleDiscoveryService._internal();
  factory BleDiscoveryService() => _instance;
  BleDiscoveryService._internal();

  StreamSubscription<List<fbp.ScanResult>>? _scanSubscription;
  Timer? _scanDiagnosticsTimer;

  final _discoveredDevices = <String, DeviceModel>{};
  final _deviceController = StreamController<List<DeviceModel>>.broadcast();
  final ScanLogStorage _scanLogStorage = ScanLogStorage.instance;

  int _totalScanResultsReceived = 0;

  /// Stream of discovered BLE peers (UUID-keyed, discovery only).
  Stream<List<DeviceModel>> get discoveredDevices => _deviceController.stream;

  // ── Retry constants ──────────────────────────────────────────────
  static const int _maxScanRetries = 3;
  static const Duration _scanRetryDelay = Duration(milliseconds: 1500);

  // ── Initialization ───────────────────────────────────────────────

  /// Verify BLE adapter is ready. Must be called before startScan.
  Future<bool> initialize() async {
    try {
      final isAvailable = await fbp.FlutterBluePlus.isSupported;
      if (!isAvailable) {
        Logger.warning('BleDiscoveryService: BLE not supported on this device');
        return false;
      }
      final adapterState = await fbp.FlutterBluePlus.adapterState.first;
      if (adapterState != fbp.BluetoothAdapterState.on) {
        Logger.warning('BleDiscoveryService: BLE adapter is not ON');
        return false;
      }
      Logger.info('BleDiscoveryService: initialized');
      return true;
    } catch (e) {
      Logger.error('BleDiscoveryService: error during initialization', e);
      return false;
    }
  }

  // ── Scanning ─────────────────────────────────────────────────────

  /// Start BLE scan for nearby Offlink peers.
  ///
  /// Peers are identified exclusively via manufacturer data (key 0xFFFF)
  /// which embeds the Device UUID (16 bytes) and username (variable).
  Future<void> startScan({int retryCount = 0}) async {
    try {
      final adapterState = await fbp.FlutterBluePlus.adapterState.first;
      if (adapterState != fbp.BluetoothAdapterState.on) {
        Logger.error('BleDiscoveryService: BLE adapter is not ON, cannot scan');
        await _scanLogStorage.logEvent(
          'BLE discovery scan failed: adapter not ON',
          metadata: {'adapterState': adapterState.toString()},
        );
        throw Exception('BLE adapter is not ON');
      }

      _discoveredDevices.clear();
      _totalScanResultsReceived = 0;

      await _scanLogStorage.logEvent(
        'BLE discovery scan requested',
        metadata: {'retryCount': retryCount},
      );

      Logger.info(
          'BleDiscoveryService: starting scan (attempt ${retryCount + 1}/$_maxScanRetries)');

      _scanSubscription?.cancel();
      _scanSubscription = fbp.FlutterBluePlus.scanResults.listen(
        (results) => _processScanResults(results),
        onError: (error) {
          Logger.error('BleDiscoveryService: scan stream error', error);
          unawaited(_scanLogStorage.logEvent(
            'BLE discovery scan stream error',
            metadata: {'error': error.toString()},
          ));
        },
      );

      await fbp.FlutterBluePlus.startScan(
        timeout: AppConstants.bleScanTimeout,
        androidScanMode: fbp.AndroidScanMode.lowLatency,
      );

      await Future.delayed(const Duration(milliseconds: 100));
      if (!fbp.FlutterBluePlus.isScanningNow) {
        throw Exception('BLE scan did not start — scanner may have failed to register');
      }

      Logger.info('BleDiscoveryService: scan started successfully');
      await _scanLogStorage.logEvent(
        'BLE discovery scan started',
        metadata: {'retryCount': retryCount},
      );

      _scanDiagnosticsTimer?.cancel();
      _scanDiagnosticsTimer = Timer(const Duration(seconds: 5), () {
        if (_totalScanResultsReceived == 0) {
          Logger.warning('BleDiscoveryService: no scan results after 5 s');
        }
      });
    } on fbp.FlutterBluePlusException catch (e) {
      final isRegFailure = e.code == 2 ||
          e.description?.contains('APPLICATION_REGISTRATION_FAILED') == true;

      unawaited(_scanLogStorage.logEvent(
        'BLE discovery scan start failure',
        metadata: {
          'error': e.toString(),
          'retryCount': retryCount,
          'isRegFailure': isRegFailure,
        },
      ));

      if (isRegFailure) {
        // Hardware / firmware limitation — the scanner registration slot is
        // exhausted on this device.  Retrying causes repeated GATT-server
        // suspend/resume cycles with no benefit.  Throw immediately so the
        // caller can show a helpful message and keep advertising running.
        Logger.warning(
            'BleDiscoveryService: APPLICATION_REGISTRATION_FAILED — '
            'hardware limitation, skipping retries');
        rethrow;
      }

      // Non-registration failure — retry with back-off.
      if (retryCount < _maxScanRetries - 1) {
        Logger.warning('BleDiscoveryService: scan start error, retrying…');
        await Future.delayed(_scanRetryDelay);
        return startScan(retryCount: retryCount + 1);
      }
      Logger.error('BleDiscoveryService: scan start error', e);
      rethrow;
    } catch (e) {
      final errorStr = e.toString().toLowerCase();
      final isRegFailure = errorStr.contains('application_registration_failed') ||
          errorStr.contains('scan did not start');

      unawaited(_scanLogStorage.logEvent(
        'BLE discovery scan start failure',
        metadata: {'error': e.toString(), 'retryCount': retryCount},
      ));

      if (isRegFailure) {
        // Same hardware limitation — don't retry.
        Logger.warning(
            'BleDiscoveryService: scanner registration failure (generic) — '
            'skipping retries');
        rethrow;
      }

      // Retry for other transient errors only.
      if (retryCount < _maxScanRetries - 1) {
        Logger.warning(
            'BleDiscoveryService: possible transient scan error, retrying…');
        await Future.delayed(_scanRetryDelay);
        return startScan(retryCount: retryCount + 1);
      }
      Logger.error('BleDiscoveryService: scan start error', e);
      rethrow;
    }
  }

  /// Stop BLE scan.
  Future<void> stopScan() async {
    try {
      _scanDiagnosticsTimer?.cancel();
      _scanDiagnosticsTimer = null;

      await fbp.FlutterBluePlus.stopScan();
      await _scanSubscription?.cancel();
      _scanSubscription = null;

      Logger.info(
          'BleDiscoveryService: scan stopped. '
          'Total results: $_totalScanResultsReceived, '
          'Devices discovered: ${_discoveredDevices.length}');

      await _scanLogStorage.logEvent(
        'BLE discovery scan stopped',
        metadata: {
          'totalResults': _totalScanResultsReceived,
          'discoveredDevices': _discoveredDevices.length,
        },
      );

      _totalScanResultsReceived = 0;
    } catch (e) {
      Logger.error('BleDiscoveryService: error stopping scan', e);
    }
  }

  // ── Scan result processing ────────────────────────────────────────

  void _processScanResults(List<fbp.ScanResult> results) {
    _totalScanResultsReceived += results.length;
    Logger.debug(
        'BleDiscoveryService: ${results.length} raw scan result(s) received');

    for (final result in results) {
      final macAddress = result.device.remoteId.str;

      // ── Extract Device UUID from manufacturer data (key 0xFFFF) ──
      String? deviceUuid;
      String? extractedUsername;

      try {
        final mfgData = result.advertisementData.manufacturerData;

        // ── Step 1: Extract Device UUID from primary advertisement (0xFFFF) ──
        if (mfgData.containsKey(0xFFFF)) {
          final uuidBytes = mfgData[0xFFFF]!;
          if (uuidBytes.length >= 16) {
            deviceUuid = _bytesToUuid(uuidBytes.sublist(0, 16));

            // Legacy format: username was packed after UUID in 0xFFFF
            // [UUID=16 bytes][usernameLen=1 byte][username bytes…]
            if (uuidBytes.length > 17) {
              final usernameLen = uuidBytes[16] & 0xFF;
              if (usernameLen > 0 && uuidBytes.length >= 17 + usernameLen) {
                extractedUsername = String.fromCharCodes(
                    uuidBytes.sublist(17, 17 + usernameLen));
                Logger.debug(
                    'BleDiscoveryService: extracted username "$extractedUsername" '
                    'from legacy 0xFFFF manufacturer data');
              }
            }
          }
        }

        // ── Step 2: Extract username from scan response (0xFFFE) ──
        // New format: UUID in primary ad (0xFFFF), username in scan response (0xFFFE)
        // Format: [usernameLen=1 byte][username bytes…]
        // flutter_blue_plus merges primary ad + scan response into one map,
        // so both 0xFFFF and 0xFFFE are accessible here.
        if (mfgData.containsKey(0xFFFE)) {
          final payload = mfgData[0xFFFE]!;
          if (payload.isNotEmpty) {
            final usernameLen = payload[0] & 0xFF;
            if (usernameLen > 0 && payload.length >= 1 + usernameLen) {
              extractedUsername = String.fromCharCodes(
                  payload.sublist(1, 1 + usernameLen));
              Logger.debug(
                  'BleDiscoveryService: extracted username "$extractedUsername" '
                  'from scan response (0xFFFE)');
            }
          }
        }
      } catch (e) {
        Logger.debug('BleDiscoveryService: manufacturer data parse error: $e');
      }

      // Skip devices that are not Offlink peers
      if (deviceUuid == null) {
        Logger.debug(
            'BleDiscoveryService: skipping device without UUID — not an Offlink peer ($macAddress)');
        continue;
      }

      // Store UUID ↔ MAC mapping for future Wi-Fi Direct/BLE operations
      unawaited(DeviceStorage.setMacForUuid(deviceUuid, macAddress));

      // ── Resolve display name (extracted username > stored name > BLE name) ──
      final storedName = DeviceStorage.getDeviceDisplayName(deviceUuid);
      final bleName = result.device.platformName.isNotEmpty
          ? result.device.platformName
          : null;

      // Prefer freshly extracted username; fall back to stored name, then BLE
      // device name.  "Unknown Device" / "Unknown" are never used as the final
      // display name — they're treated as absent.
      bool _isUnknown(String? s) =>
          s == null || s.isEmpty || s == 'Unknown Device' || s == 'Unknown';

      String displayName;
      if (!_isUnknown(extractedUsername)) {
        displayName = extractedUsername!;
        // Persist if not already stored (or if stored name was a placeholder)
        if (_isUnknown(storedName)) {
          unawaited(DeviceStorage.setDeviceDisplayName(deviceUuid, displayName));
        }
      } else if (!_isUnknown(storedName)) {
        displayName = storedName!;
      } else if (!_isUnknown(bleName)) {
        displayName = bleName!;
        unawaited(DeviceStorage.setDeviceDisplayName(deviceUuid, displayName));
      } else {
        displayName = 'Unknown Device';
      }

      // If the device is already in the list with an "Unknown" placeholder and
      // we now have a real name, update the entry so the UI reflects it.
      final existing = _discoveredDevices[deviceUuid];
      if (existing != null &&
          _isUnknown(existing.name) &&
          !_isUnknown(displayName)) {
        Logger.info(
            'BleDiscoveryService: updating placeholder name for $deviceUuid '
            '"${existing.name}" → "$displayName"');
      }

      final device = DeviceModel(
        id: deviceUuid,        // Always UUID, never MAC
        name: displayName,
        address: macAddress,   // MAC kept for native BLE operations only
        type: DeviceType.ble,
        rssi: result.rssi,
        lastSeen: DateTime.now(),
      );

      _discoveredDevices[deviceUuid] = device;
      _deviceController.add(_discoveredDevices.values.toList());

      // ── Persist to Known Contacts database ───────────────────────
      // Every discovered peer is saved so users can send messages
      // even when the peer goes out of range (store-and-forward).
      unawaited(KnownContactsStorage.saveContact(
        peerId: deviceUuid,
        displayName: displayName,
        deviceAddress: macAddress,
      ));

      Logger.info(
          'BleDiscoveryService: discovered peer "$displayName" '
          '(UUID: $deviceUuid, MAC: $macAddress, RSSI: ${result.rssi})');
    }
  }

  // ── UUID byte conversion ─────────────────────────────────────────

  /// Convert 16-byte big-endian representation to UUID string.
  String? _bytesToUuid(List<int> bytes) {
    try {
      if (bytes.length < 16) return null;
      int msb = 0;
      int lsb = 0;
      for (int i = 0; i < 8; i++) {
        msb = msb | ((bytes[i] & 0xFF) << (56 - i * 8));
      }
      for (int i = 0; i < 8; i++) {
        lsb = lsb | ((bytes[8 + i] & 0xFF) << (56 - i * 8));
      }
      final timeLow = (msb >> 32) & 0xFFFFFFFF;
      final timeMid = (msb >> 16) & 0xFFFF;
      final timeHiVer = msb & 0xFFFF;
      final clockHi = (lsb >> 56) & 0xFF;
      final clockLo = (lsb >> 48) & 0xFF;
      final node = lsb & 0xFFFFFFFFFFFF;
      return '${timeLow.toRadixString(16).padLeft(8, '0')}-'
          '${timeMid.toRadixString(16).padLeft(4, '0')}-'
          '${timeHiVer.toRadixString(16).padLeft(4, '0')}-'
          '${clockHi.toRadixString(16).padLeft(2, '0')}'
          '${clockLo.toRadixString(16).padLeft(2, '0')}-'
          '${node.toRadixString(16).padLeft(12, '0')}'
              .toLowerCase();
    } catch (e) {
      Logger.debug('BleDiscoveryService: UUID byte conversion failed: $e');
      return null;
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────

  void dispose() {
    _scanDiagnosticsTimer?.cancel();
    _scanSubscription?.cancel();
    _deviceController.close();
  }
}
