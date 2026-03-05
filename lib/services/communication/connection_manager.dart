import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:device_info_plus/device_info_plus.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../models/message_model.dart';
import '../../models/peer_connection_model.dart';
import '../../utils/logger.dart';
import '../../utils/permissions_helper.dart';
import '../storage/scan_log_storage.dart';
import '../storage/device_storage.dart';
import '../routing/routing_manager.dart';
import 'transport_manager.dart';
import 'ble_discovery_service.dart';      // ← Control Plane (discovery only)
import 'ble_peripheral_service.dart';
import 'wifi_direct_service.dart';        // ← Data Plane (primary transport)

// ─────────────────────────────────────────────────────────────────────────────
// Dual-Radio Architecture
//
//  BLE (Control Plane)
//    BleDiscoveryService  — scans for nearby peers, extracts UUID + username
//    BlePeripheralService — advertises our UUID + username to be discoverable
//
//  Wi-Fi Direct (Data Plane)
//    WifiDirectService    — P2P group negotiation + TCP socket + messaging
//    TransportManager     — routes bytes to WifiDirectService
//    RoutingManager       — transport-agnostic dedup / TTL / local delivery
//
// Connection flow:
//   BLE discovers peer → user taps → initiateWifiDirectConnection()
//   → WifiDirectService.initiateConnection() → socket open
//   → TransportManager.addNeighbor() → chat over Wi-Fi Direct
//
// BLE is NEVER used to carry chat payload.
// ─────────────────────────────────────────────────────────────────────────────

enum ConnectionType {
  wifiDirect,
  none,
}

/// Connection state exposed to the UI.
enum ConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

class ConnectionManager {
  static final ConnectionManager _instance = ConnectionManager._internal();
  factory ConnectionManager() => _instance;

  ConnectionManager._internal() {
    // ── BLE Discovery → merge into device list ────────────────────
    _bleDiscoverySubscription =
        _bleDiscoveryService.discoveredDevices.listen((devices) {
      _bleDevices = devices;
      _emitDiscoveredDevices();
    });

    // ── Native scan results (TECNO / problematic-device fallback) ──
    _nativeScanSubscription =
        _blePeripheralService.scanResults.listen(_handleNativeScanResult);
  }

  // ── Services ──────────────────────────────────────────────────────
  final BleDiscoveryService _bleDiscoveryService = BleDiscoveryService();
  final BlePeripheralService _blePeripheralService = BlePeripheralService();
  final WifiDirectService _wifiDirectService = WifiDirectService();

  // ── Routing / Transport layers ────────────────────────────────────
  final RoutingManager _routingManager = RoutingManager();
  final TransportManager _transportManager = TransportManager();

  // ── State ─────────────────────────────────────────────────────────
  ConnectionType _currentConnectionType = ConnectionType.none;

  /// UUID of the currently connected peer (Wi-Fi Direct).
  String? _connectedPeerId;

  /// DeviceModel cached after a successful Wi-Fi Direct negotiation.
  DeviceModel? _connectedDevice;

  // ── Streams (exposed to UI / providers) ──────────────────────────
  final _connectionController =
      StreamController<ConnectionState>.broadcast();
  final _messageController = StreamController<String>.broadcast();
  final _deviceStreamController =
      StreamController<List<DeviceModel>>.broadcast();
  final _invitationController =
      StreamController<Map<String, String>>.broadcast();

  Stream<ConnectionState> get connectionState => _connectionController.stream;
  Stream<String> get incomingMessages => _messageController.stream;

  /// Fires when a remote device sends a Wi-Fi Direct connection invitation.
  /// Map keys: "deviceName" and "deviceAddress".
  Stream<Map<String, String>> get incomingInvitations =>
      _invitationController.stream;

  // ── Device caches ─────────────────────────────────────────────────
  List<DeviceModel> _bleDevices = const [];
  final Map<String, DeviceModel> _nativeScanDevices = {};

  // ── Flags ─────────────────────────────────────────────────────────
  bool _peripheralInitialized = false;
  bool _peripheralListening = false;
  bool _isAdvertising = false;
  bool _isInitialized = false;
  bool _useNativeScanner = false;
  bool _nativeScannerFailed = false;

  // ── Subscriptions ─────────────────────────────────────────────────
  StreamSubscription<List<DeviceModel>>? _bleDiscoverySubscription;
  StreamSubscription<Map<String, dynamic>>? _nativeScanSubscription;
  StreamSubscription<Map<String, dynamic>>? _peripheralConnectionStateSubscription;
  StreamSubscription<WifiDirectConnectionState>? _wifiConnectionStateSubscription;
  StreamSubscription<String>? _wifiIncomingMessagesSubscription;
  StreamSubscription<Map<String, String>>? _wifiInvitationSubscription;

  // ── Public getters ────────────────────────────────────────────────
  ConnectionType get currentConnectionType => _currentConnectionType;
  DeviceModel? get connectedDevice => _connectedDevice;

  // ═══════════════════════════════════════════════════════════════════
  // Initialization
  // ═══════════════════════════════════════════════════════════════════

  Future<bool> initialize() async {
    if (_isInitialized) {
      await _ensurePeripheralStarted();
      return true;
    }
    try {
      // ── Control Plane: BLE discovery ──────────────────────────────
      final bleInitialized = await _bleDiscoveryService.initialize();

      // ── Data Plane: Wi-Fi Direct ──────────────────────────────────
      final wifiInitialized = await _wifiDirectService.initialize();

      // ── RoutingManager → message controller ──────────────────────
      _routingManager.localMessages.listen((message) {
        Logger.info(
            'RoutingManager: locally delivered message for ${message.finalReceiverId}');
        _messageController.add(jsonEncode(message.toJson()));
      });

      // ── Wi-Fi Direct: incoming messages ──────────────────────────
      _wifiIncomingMessagesSubscription?.cancel();
      _wifiIncomingMessagesSubscription =
          _wifiDirectService.incomingMessages.listen((message) {
        Logger.info('ConnectionManager: message received via Wi-Fi Direct');
        _handleIncomingMessage(message);
      });

      // ── Wi-Fi Direct: connection state ───────────────────────────
      _wifiConnectionStateSubscription?.cancel();
      _wifiConnectionStateSubscription =
          _wifiDirectService.connectionState.listen(_handleWifiDirectState);

      // ── Wi-Fi Direct: incoming invitations ────────────────────────
      _wifiInvitationSubscription?.cancel();
      _wifiInvitationSubscription =
          _wifiDirectService.incomingInvitations.listen((payload) {
        Logger.info(
            'ConnectionManager: incoming invitation from ${payload["deviceName"]}');
        _invitationController.add(payload);
      });

      // ── Device-specific scan mode detection ──────────────────────
      _useNativeScanner = await _shouldUseNativeScanner();
      Logger.info('Native scanner mode: $_useNativeScanner');

      final initialized = bleInitialized || wifiInitialized;
      Logger.info('ConnectionManager initialized '
          '(BLE discovery: $bleInitialized, Wi-Fi Direct: $wifiInitialized)');

      if (initialized) {
        _isInitialized = true;
        if (bleInitialized) {
          unawaited(_ensurePeripheralStarted());
        }
      }

      return initialized;
    } catch (e) {
      Logger.error('Error initializing ConnectionManager', e);
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Wi-Fi Direct connection state handler
  // ═══════════════════════════════════════════════════════════════════

  void _handleWifiDirectState(WifiDirectConnectionState state) {
    try {
      Logger.info(
          'ConnectionManager: Wi-Fi Direct state — '
          'connected=${state.connected}, role=${state.role}, '
          'socketActive=${state.socketActive}, error=${state.error}');

      if (state.connected && state.socketActive) {
        // ── Socket open ────────────────────────────────────────────
        // Always send a UUID handshake so the RECEIVING side (which never
        // called connectToDevice) can learn our UUID before chat opens.
        _sendUuidHandshake();

        if (_connectedPeerId != null) {
          // ── INITIATOR side: we already know the peer UUID ─────────
          final role = state.isGroupOwner
              ? ConnectionRole.peripheral // GO == server
              : ConnectionRole.central;   // client

          final peerName =
              _connectedDevice?.name ??
              DeviceStorage.getDeviceDisplayName(_connectedPeerId!) ??
              'Offlink Peer';

          final device = DeviceModel(
            id: _connectedPeerId!,
            name: peerName,
            type: DeviceType.wifiDirect,
            isConnected: true,
          );

          final peerConnection = _transportManager.createPeerConnection(
            device: device,
            transportType: TransportType.wifiDirect,
            role: role,
            ipAddress: state.ipAddress,
            socketActive: true,
          );
          _transportManager.addNeighbor(peerConnection);

          _connectedDevice = device;
          _currentConnectionType = ConnectionType.wifiDirect;
          _connectionController.add(ConnectionState.connected);

          Logger.info(
              'ConnectionManager: ✅ Wi-Fi Direct fully connected (initiator) — '
              'peerId=${_connectedPeerId!}, role=${role.name}, ip=${state.ipAddress}');
        } else {
          // ── RECEIVING side: peer UUID unknown until handshake ─────
          // Register a placeholder so the transport layer is ready to
          // send the handshake reply. State stays "connecting" until
          // _handleUuidHandshake() resolves the real UUID.
          final role = state.isGroupOwner
              ? ConnectionRole.peripheral
              : ConnectionRole.central;

          const placeholderId = '__uuid_pending__';
          final placeholderDevice = DeviceModel(
            id: placeholderId,
            name: 'Connecting…',
            type: DeviceType.wifiDirect,
            isConnected: true,
          );
          final peerConnection = _transportManager.createPeerConnection(
            device: placeholderDevice,
            transportType: TransportType.wifiDirect,
            role: role,
            ipAddress: state.ipAddress,
            socketActive: true,
          );
          _transportManager.addNeighbor(peerConnection);
          _currentConnectionType = ConnectionType.wifiDirect;

          // Stay in "connecting" state — will flip to "connected" in
          // _handleUuidHandshake() once the peer's UUID is received.
          _connectionController.add(ConnectionState.connecting);
          Logger.info(
              'ConnectionManager: Wi-Fi Direct socket open (receiver) — '
              'awaiting UUID handshake from initiator…');
        }

      } else if (state.connected && !state.socketActive) {
        // P2P group formed but socket not yet open
        _connectionController.add(ConnectionState.connecting);
        Logger.info('ConnectionManager: Wi-Fi Direct group formed, awaiting socket…');

      } else if (!state.connected) {
        if (state.status == 'connecting') {
          // ── connect() request accepted — P2P group is forming ────────
          // This is a transitional state fired by the native layer when
          // WifiP2pManager.connect() is accepted.  Do NOT clear
          // _connectedPeerId — the initiator side needs it when the socket
          // opens.  The UI should stay in "connecting" state.
          _connectionController.add(ConnectionState.connecting);
          Logger.info(
              'ConnectionManager: Wi-Fi Direct connect() accepted — '
              'awaiting group formation…');
        } else {
          // ── Actual disconnect or failure ─────────────────────────────
          final reason = state.error ?? 'disconnected';
          Logger.info('ConnectionManager: Wi-Fi Direct disconnected — $reason');

          final idToRemove = _connectedPeerId ?? '__uuid_pending__';
          _transportManager.removeNeighbor(idToRemove);

          _currentConnectionType = ConnectionType.none;
          _connectedDevice = null;
          _connectedPeerId = null;

          // Emit error vs. clean disconnect so the UI can show the right message
          if (state.error != null) {
            _connectionController.add(ConnectionState.error);
          } else {
            _connectionController.add(ConnectionState.disconnected);
          }

          // BLE continues scanning in background — no action needed here.
          // User can reconnect by tapping the device again in the UI.
        }
      }
    } catch (e, st) {
      Logger.error('ConnectionManager: error handling Wi-Fi Direct state', e, st);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // UUID Handshake — mutual UUID exchange over the socket
  // ═══════════════════════════════════════════════════════════════════

  /// Sends our UUID to the peer immediately after the socket opens.
  /// Both sides do this so neither needs to know the other's UUID in advance.
  void _sendUuidHandshake() {
    try {
      final myUuid = DeviceStorage.getDeviceId();
      final handshake = jsonEncode({
        '__type': '__uuid_handshake__',
        'senderUuid': myUuid,
      });
      // Use the service directly — transport map may still be placeholder.
      _wifiDirectService.sendMessage(handshake);
      Logger.info('ConnectionManager: 🤝 sent UUID handshake (myUuid=$myUuid)');
    } catch (e) {
      Logger.error('ConnectionManager: failed to send UUID handshake', e);
    }
  }

  /// Called when a `__uuid_handshake__` message is received from the peer.
  /// Resolves the peer UUID so routing and the UI use the correct identity.
  void _handleUuidHandshake(Map<String, dynamic> handshake) {
    try {
      final senderUuid = handshake['senderUuid'] as String?;
      if (senderUuid == null || senderUuid.isEmpty) {
        Logger.warning('ConnectionManager: UUID handshake missing senderUuid');
        return;
      }

      Logger.info(
          'ConnectionManager: 🤝 received UUID handshake — peerUuid=$senderUuid');

      if (_connectedPeerId == null || _connectedPeerId == '__uuid_pending__') {
        // ── RECEIVING side: update from placeholder to real UUID ───
        final oldId = _connectedPeerId ?? '__uuid_pending__';
        _connectedPeerId = senderUuid;

        // Remove placeholder neighbor
        _transportManager.removeNeighbor(oldId);

        // Look up a stored name for this peer (if they were seen via BLE before)
        final peerName =
            DeviceStorage.getDeviceDisplayName(senderUuid) ?? 'Offlink Peer';

        final lastState = _wifiDirectService.lastKnownState;
        final role = lastState.isGroupOwner
            ? ConnectionRole.peripheral
            : ConnectionRole.central;

        final device = DeviceModel(
          id: senderUuid,
          name: peerName,
          type: DeviceType.wifiDirect,
          isConnected: true,
        );

        final peerConnection = _transportManager.createPeerConnection(
          device: device,
          transportType: TransportType.wifiDirect,
          role: role,
          ipAddress: lastState.ipAddress,
          socketActive: true,
        );
        _transportManager.addNeighbor(peerConnection);

        _connectedDevice = device;
        _currentConnectionType = ConnectionType.wifiDirect;
        _connectionController.add(ConnectionState.connected);

        Logger.info(
            'ConnectionManager: ✅ peer UUID resolved from handshake — '
            'peerId=$senderUuid, name=$peerName');
      } else {
        // ── INITIATOR side: handshake reply confirms peer is ready ──
        Logger.info(
            'ConnectionManager: peer confirmed UUID handshake '
            '(our _connectedPeerId=${_connectedPeerId!})');
      }
    } catch (e) {
      Logger.error('ConnectionManager: error handling UUID handshake', e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Scanning (Control Plane — BLE only)
  // ═══════════════════════════════════════════════════════════════════

  Future<void> startScan({bool useBle = true}) async {
    bool advertisingWasStopped = false;
    try {
      // Android 13+ BLE scanning prerequisites
      if (useBle && Platform.isAndroid) {
        final androidInfo = await DeviceInfoPlugin().androidInfo;
        if (androidInfo.version.sdkInt >= 33) {
          final locationEnabled =
              await PermissionsHelper.isLocationEnabled();
          if (!locationEnabled) {
            throw Exception(
              'Location services must be enabled for BLE scanning on Android 13+.\n\n'
              'Please enable Location in your device settings and try again.',
            );
          }
          final permissionsGranted =
              await PermissionsHelper.checkBluetoothPermissions();
          if (!permissionsGranted) {
            throw Exception(
              'All Bluetooth permissions are required for scanning on Android 13+.\n\n'
              'Please grant BLUETOOTH_SCAN, BLUETOOTH_CONNECT, '
              'BLUETOOTH_ADVERTISE, and Location permissions.',
            );
          }
          Logger.info(
              '✅ Android 13+ BLE requirements verified: '
              'Location enabled, permissions granted');
        }
      }

      _nativeScanDevices.clear();

      try {
        await _bleDiscoveryService.stopScan();
        await _blePeripheralService.stopNativeScan();
      } catch (e) {
        Logger.debug('No existing scan to stop: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));

      final shouldStopAds = await _shouldStopAdvertisingForScan();
      Logger.info('Should stop advertising for scan: $shouldStopAds');

      if (shouldStopAds) {
        Logger.info('Suspending peripheral role for scanning');
        try {
          await _blePeripheralService.suspendForScanning();
          Logger.info('Peripheral suspended successfully');
        } catch (e) {
          Logger.error('Error suspending peripheral: $e');
          rethrow;
        }
        _isAdvertising = false;
        advertisingWasStopped = true;

        final delayMs = await _getScanDelayForDevice();
        Logger.info('Waiting ${delayMs}ms for BLE stack to settle…');
        await Future.delayed(Duration(milliseconds: delayMs));
      } else {
        await _ensurePeripheralStarted();
      }

      if (useBle) {
        // ── Native scanner first for problematic devices ──────────
        if (_useNativeScanner && !_nativeScannerFailed) {
          Logger.info('Using native BLE scanner (TECNO mode)');
          final result = await _blePeripheralService.startNativeScan(
            timeoutMs: AppConstants.bleScanTimeout.inMilliseconds,
          );
          if (result['success'] == true && result['mode'] != 'classic') {
            Logger.info('Native BLE scan started successfully');
            unawaited(_scanLogStorage.logEvent(
              'Native BLE scan started',
              metadata: {
                'retry': result['retry'] ?? 0,
                'mode': result['mode'] ?? 'ble',
              },
            ));
            return;
          } else {
            Logger.warning(
                'Native scan failed or fell back to Classic: '
                '${result['error'] ?? result['mode']}');
            _nativeScannerFailed = true;
          }
        }

        // ── BleDiscoveryService (flutter_blue_plus) ───────────────
        Logger.info('Using BleDiscoveryService scanner');
        try {
          await _bleDiscoveryService.startScan();
          Logger.info('BLE discovery scan started successfully');
          unawaited(_scanLogStorage.logEvent(
            'BLE discovery scan started',
            metadata: {'nativeScannerFailed': _nativeScannerFailed},
          ));
        } catch (e) {
          Logger.error('BleDiscoveryService scan failed: $e');
          _nativeScannerFailed = true;

          final errorStr = e.toString().toLowerCase();
          final isRegFailure = errorStr.contains('registration') ||
              errorStr.contains('application_registration_failed') ||
              errorStr.contains('scan_failed_application_registration_failed');

          if (isRegFailure) {
            Logger.warning(
                '⚠️ BLE scanner registration failed — trying Classic as last resort…');
            unawaited(_scanLogStorage.logEvent(
              'All BLE scan methods failed — trying Classic discovery',
              metadata: {
                'error': e.toString(),
                'nativeScannerFailed': _nativeScannerFailed,
              },
            ));
            try {
              final classicResult =
                  await _blePeripheralService.startNativeScan(
                timeoutMs: 12000,
              );
              if (classicResult['success'] == true &&
                  classicResult['mode'] == 'classic') {
                Logger.warning(
                    '⚠️ Using Classic Bluetooth discovery (will not find BLE-only devices)');
                return;
              }
            } catch (classicError) {
              Logger.error('Classic discovery also failed: $classicError');
            }
            throw Exception(
              'Scanning is not available on this device due to a firmware limitation.\n\n'
              'Solution: Ask the other device to scan for you instead. '
              'You will receive a connection notification when they find you.',
            );
          } else {
            unawaited(_scanLogStorage.logEvent(
              'All BLE scan methods failed',
              metadata: {
                'error': e.toString(),
                'nativeScannerFailed': _nativeScannerFailed,
              },
            ));
            rethrow;
          }
        }
      }

      unawaited(_scanLogStorage.logEvent(
        'Device scan started',
        metadata: {
          'ble': useBle,
          'useNative': _useNativeScanner && !_nativeScannerFailed,
          'advertisingStopped': advertisingWasStopped,
        },
      ));
    } catch (e) {
      Logger.error('Error starting device scan', e);
      unawaited(_scanLogStorage.logEvent(
        'Device scan start failure',
        metadata: {
          'error': e.toString(),
          'advertisingWasStopped': advertisingWasStopped,
        },
      ));
      if (advertisingWasStopped) {
        await _restartAdvertisingAfterScan();
      }
      rethrow;
    }
  }

  Future<void> stopScan() async {
    try {
      await _bleDiscoveryService.stopScan();
      await _blePeripheralService.stopNativeScan();

      Logger.info('Device scan stopped');
      unawaited(_scanLogStorage.logEvent('Device scan stopped'));

      final shouldRestart = await _shouldStopAdvertisingForScan();
      if (shouldRestart && !_isAdvertising) {
        await _restartAdvertisingAfterScan();
      }
    } catch (e) {
      Logger.error('Error stopping device scan', e);
      final shouldRestart = await _shouldStopAdvertisingForScan();
      if (shouldRestart && !_isAdvertising) {
        unawaited(_restartAdvertisingAfterScan());
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Connection (Data Plane — Wi-Fi Direct)
  // ═══════════════════════════════════════════════════════════════════

  /// Connect to a BLE-discovered peer via Wi-Fi Direct.
  ///
  /// Regardless of how the device was discovered (BLE or native scan),
  /// the data-plane connection is always Wi-Fi Direct.
  Future<bool> connectToDevice(DeviceModel device) async {
    try {
      // Stop BLE scan to free radio resources (Wi-Fi Direct also needs them)
      Logger.info(
          'ConnectionManager: stopping BLE scan before Wi-Fi Direct connect');
      try {
        await stopScan();
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        Logger.warning('Error stopping scan before connect: $e');
      }

      _connectionController.add(ConnectionState.connecting);
      Logger.info(
          'ConnectionManager: initiating Wi-Fi Direct connection to "${device.name}"');

      // Store the peer UUID — this is the single authoritative identity key.
      // UUID comes from BLE discovery; it is never a MAC address.
      _connectedPeerId = device.id;

      // Store display name
      if (device.name.isNotEmpty &&
          device.name != 'Unknown Device' &&
          device.name != device.id &&
          !device.id.contains(':')) {
        final stored = DeviceStorage.getDeviceDisplayName(device.id);
        if (stored == null || stored == device.id) {
          unawaited(DeviceStorage.setDeviceDisplayName(device.id, device.name));
          Logger.info(
              'ConnectionManager: stored device name "${device.name}" for ${device.id}');
        }
      }

      // ── Initiate Wi-Fi Direct negotiation ────────────────────────
      final result =
          await _wifiDirectService.initiateConnection(targetName: device.name);

      if (result['success'] == true) {
        Logger.info(
            'ConnectionManager: Wi-Fi Direct negotiation started — '
            'awaiting connection state events…');
        // The actual PeerConnection is registered in _handleWifiDirectState
        // once the socket is established (socketActive == true).
        unawaited(_scanLogStorage.logEvent(
          'Wi-Fi Direct connection initiated',
          metadata: {'peerId': device.id, 'peerName': device.name},
        ));

        // Restart advertising so we remain discoverable to other peers
        Logger.info(
            'ConnectionManager: restarting BLE advertising after Wi-Fi Direct connect');
        await Future.delayed(const Duration(milliseconds: 500));
        unawaited(_ensurePeripheralStarted());

        return true;
      } else {
        final error = result['error'] ?? 'unknown error';
        Logger.error(
            'ConnectionManager: Wi-Fi Direct connection failed — $error');
        _connectedPeerId = null;
        _connectionController.add(ConnectionState.disconnected);
        unawaited(_scanLogStorage.logEvent(
          'Wi-Fi Direct connection failed',
          metadata: {
            'peerId': device.id,
            'peerName': device.name,
            'error': error,
          },
        ));
        return false;
      }
    } catch (e) {
      Logger.error('ConnectionManager: error connecting to device', e);
      _connectedPeerId = null;
      _connectionController.add(ConnectionState.disconnected);
      return false;
    }
  }

  /// Disconnect from the current Wi-Fi Direct peer.
  Future<void> disconnect() async {
    try {
      await _wifiDirectService.disconnect();

      if (_connectedPeerId != null) {
        _transportManager.removeNeighbor(_connectedPeerId!);
      }

      _currentConnectionType = ConnectionType.none;
      _connectedDevice = null;
      _connectedPeerId = null;
      _connectionController.add(ConnectionState.disconnected);

      Logger.info(
          'ConnectionManager: disconnected. Restarting BLE advertising…');
      await Future.delayed(const Duration(milliseconds: 500));
      unawaited(_ensurePeripheralStarted());
    } catch (e) {
      Logger.error('ConnectionManager: error disconnecting', e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Invitation consent
  // ═══════════════════════════════════════════════════════════════════

  /// Accept the pending incoming Wi-Fi Direct invitation.
  Future<void> acceptInvitation() async {
    try {
      await _wifiDirectService.acceptInvitation();
      Logger.info('ConnectionManager: invitation accepted');
    } catch (e) {
      Logger.error('ConnectionManager: acceptInvitation error', e);
    }
  }

  /// Reject the pending incoming Wi-Fi Direct invitation.
  Future<void> rejectInvitation() async {
    try {
      await _wifiDirectService.rejectInvitation();
      Logger.info('ConnectionManager: invitation rejected');
    } catch (e) {
      Logger.error('ConnectionManager: rejectInvitation error', e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Messaging  (Data Plane → TransportManager → WifiDirectService)
  // ═══════════════════════════════════════════════════════════════════

  /// Send a message to the connected peer.
  ///
  /// Path: sendMessage → RoutingManager.routeMessage →
  ///        TransportManager.sendToPeer → WifiDirectService.sendMessage
  Future<bool> sendMessage(String message) async {
    try {
      Logger.info('ConnectionManager: sendMessage called');

      if (!_transportManager.hasNeighbors()) {
        Logger.error('ConnectionManager: no Wi-Fi Direct neighbor connected');
        return false;
      }

      final peer = _transportManager.getPrimaryNeighbor();
      if (peer == null) {
        Logger.error('ConnectionManager: primary neighbor is null');
        return false;
      }

      if (!peer.socketActive) {
        Logger.error(
            'ConnectionManager: socket not active for peer ${peer.peerId}');
        return false;
      }

      final messageBytes =
          Uint8List.fromList(utf8.encode(message));

      Logger.info(
          'ConnectionManager: sending ${messageBytes.length} bytes '
          'to peer ${peer.peerId} via TransportManager');
      final success =
          await _transportManager.sendToPeer(peer.peerId, messageBytes);

      if (success) {
        Logger.info('ConnectionManager: ✅ message sent successfully');
      } else {
        Logger.error('ConnectionManager: ❌ TransportManager send failed');
      }
      return success;
    } catch (e, st) {
      Logger.error('ConnectionManager: error in sendMessage', e, st);
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Incoming message handler
  // ═══════════════════════════════════════════════════════════════════

  void _handleIncomingMessage(String message) {
    try {
      Logger.info('ConnectionManager: handling incoming message');

      final jsonMap = _tryParseJson(message);
      if (jsonMap == null) {
        Logger.warning(
            'ConnectionManager: could not parse JSON — '
            'forwarding raw for backward compat');
        _messageController.add(message);
        return;
      }

      // ── UUID handshake — intercept before routing ─────────────────
      if (jsonMap['__type'] == '__uuid_handshake__') {
        _handleUuidHandshake(jsonMap);
        return; // Do NOT route to RoutingManager or ChatNotifier
      }

      final messageModel = MessageModel.fromJson(jsonMap);
      unawaited(_routingManager.routeMessage(messageModel));
    } catch (e, st) {
      Logger.error(
          'ConnectionManager: error handling incoming message', e, st);
      _messageController.add(message); // fallback
    }
  }

  Map<String, dynamic>? _tryParseJson(String raw) {
    try {
      final cleaned = raw.trim();
      String toParse = cleaned;
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        toParse = cleaned.substring(1, cleaned.length - 1);
        toParse =
            toParse.replaceAll('\\"', '"').replaceAll('\\n', '\n');
      }
      return jsonDecode(toParse) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Status queries
  // ═══════════════════════════════════════════════════════════════════

  bool isConnected() => _currentConnectionType == ConnectionType.wifiDirect &&
      _wifiDirectService.isFullyConnected;

  Stream<List<DeviceModel>> getDiscoveredDevices() =>
      _deviceStreamController.stream;

  // ═══════════════════════════════════════════════════════════════════
  // Native scan result handler (TECNO / problematic-device fallback)
  // ═══════════════════════════════════════════════════════════════════

  void _handleNativeScanResult(Map<String, dynamic> result) {
    if (result['error'] == true) {
      final errorCode = result['errorCode'] as int?;
      final errorName =
          result['errorName'] as String? ?? 'Unknown error';
      Logger.error(
          'Native scan error: $errorName (code: $errorCode)');
      unawaited(_scanLogStorage.logEvent(
        'Native scan error',
        metadata: result,
      ));
      if (errorCode == 2) {
        Logger.warning(
            'Native BLE scanner registration failed — marking as failed');
        _nativeScannerFailed = true;
      }
      return;
    }

    final deviceId = result['id'] as String?;
    final deviceName =
        result['name'] as String? ?? 'Unknown Device';
    final rssi = result['rssi'] as int? ?? -100;
    final discoveryType =
        result['discoveryType'] as String? ?? 'ble';

    if (deviceId != null) {
      final deviceUuid = result['deviceUuid'] as String?;
      final macAddress =
          result['macAddress'] as String? ?? deviceId;
      final finalDeviceId = (deviceUuid != null && deviceUuid.isNotEmpty)
          ? deviceUuid
          : deviceId;

      final deviceType = discoveryType == 'classic'
          ? DeviceType.classicBluetooth
          : DeviceType.ble;

      final storedName =
          DeviceStorage.getDeviceDisplayName(finalDeviceId);
      String displayName = storedName ?? deviceName;

      if (deviceUuid != null &&
          finalDeviceId == deviceUuid &&
          deviceName.isNotEmpty &&
          deviceName != 'Unknown Device' &&
          deviceName != 'Unknown' &&
          deviceName != finalDeviceId &&
          deviceName != macAddress &&
          !finalDeviceId.contains(':') &&
          storedName == null) {
        unawaited(
            DeviceStorage.setDeviceDisplayName(finalDeviceId, deviceName));
        displayName = deviceName;
        Logger.info(
            'Storing discovered device name from native scan: '
            '$finalDeviceId → $deviceName');
      }

      final device = DeviceModel(
        id: finalDeviceId,
        name: displayName,
        address: macAddress,
        type: deviceType,
        rssi: rssi,
        lastSeen: DateTime.now(),
      );

      Logger.info(
          'Native scan found device: $displayName '
          '(UUID: $finalDeviceId, MAC: $macAddress)');
      _nativeScanDevices[finalDeviceId] = device;
      _emitDiscoveredDevices();

      unawaited(_scanLogStorage.logEvent(
        'Native scan device found',
        metadata: {
          'deviceId': deviceId,
          'name': deviceName,
          'rssi': rssi,
          'matchedBy': result['matchedBy'],
        },
      ));
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // BLE Peripheral (advertising so others can discover us)
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _ensurePeripheralStarted() async {
    if (_isAdvertising) return;
    try {
      if (!_peripheralInitialized) {
        final deviceUuid = DeviceStorage.getDeviceId();
        Logger.info(
            'ConnectionManager: initializing BLE peripheral, UUID=$deviceUuid');

        _peripheralInitialized = await _blePeripheralService.initialize(
          serviceUuid: AppConstants.bleServiceUuid,
          characteristicUuid: AppConstants.bleCharacteristicUuid,
          deviceUuid: deviceUuid,
        );

        // Connection state listener — handles inbound GATT connections
        // (another device connecting to our peripheral for discovery handshake)
        if (_peripheralInitialized) {
          _peripheralConnectionStateSubscription?.cancel();
          Logger.info(
              'ConnectionManager: setting up peripheral connection state listener');
          _peripheralConnectionStateSubscription =
              _blePeripheralService.connectionState.listen(
            (state) {
              Logger.debug(
                  'ConnectionManager: peripheral state event — $state');
              // In the dual-radio architecture peripheral connections are
              // discovery-handshake only. No data is exchanged over BLE.
              // We log the event and do nothing else.
            },
            onError: (e) =>
                Logger.error('Peripheral connection state stream error', e),
            onDone: () =>
                Logger.warning('Peripheral connection state stream closed'),
          );

          if (!_peripheralListening) {
            // In dual-radio mode the BLE GATT channel carries no chat data.
            // We subscribe purely to avoid uncaught stream errors.
            _blePeripheralService.incomingMessages.listen((_) {
              // BLE carries NO chat payload — discard silently.
              Logger.debug(
                  'ConnectionManager: BLE peripheral data discarded '
                  '(discovery-only mode)');
            });
            _peripheralListening = true;
          }
        }
      }

      if (!_peripheralInitialized) {
        Logger.warning('BLE peripheral not initialized — cannot advertise');
        return;
      }

      final deviceName = await _resolveDeviceName();
      final started = await _blePeripheralService.startAdvertising(
        deviceName: deviceName as String?,
      );
      _isAdvertising = started;
      if (!started) {
        Logger.warning('Failed to start BLE advertising');
      } else {
        Logger.info('ConnectionManager: BLE advertising started');
      }
    } catch (e) {
      Logger.error('Error setting up BLE peripheral', e);
    }
  }

  Future<String> _resolveDeviceName() async {
    try {
      final displayName = DeviceStorage.getDisplayName();
      if (displayName != null && displayName.isNotEmpty) return displayName;
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        return 'Offlink ${info.model}';
      }
      return 'Offlink Device';
    } catch (e) {
      Logger.warning('Unable to resolve device name: $e');
      return 'Offlink Device';
    }
  }

  /// Restart advertising with updated device name (called after settings change).
  Future<void> restartAdvertising() async {
    try {
      await _blePeripheralService.stopAdvertising();
      _isAdvertising = false;
      await Future.delayed(const Duration(milliseconds: 200));
      await _ensurePeripheralStarted();
    } catch (e) {
      Logger.error('Error restarting advertising', e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Device list helpers
  // ═══════════════════════════════════════════════════════════════════

  void _emitDiscoveredDevices() {
    final Map<String, DeviceModel> combined = {};
    for (final d in _bleDevices) {
      combined[d.id] = d;
    }
    // Native-scan devices take priority (fresher RSSI / more metadata)
    for (final d in _nativeScanDevices.values) {
      combined[d.id] = d;
    }
    _deviceStreamController.add(combined.values.toList());
  }

  // ═══════════════════════════════════════════════════════════════════
  // Device-specific scan helpers
  // ═══════════════════════════════════════════════════════════════════

  Future<bool> _shouldUseNativeScanner() async {
    if (!Platform.isAndroid) return false;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final m = info.manufacturer.toLowerCase();
      final mo = info.model.toLowerCase();
      final b = info.brand.toLowerCase();
      Logger.info(
          'Device: manufacturer=$m, model=$mo, brand=$b');
      const patterns = [
        'tecno', 'infinix', 'itel', 'transsion', 'cla', 'camon',
      ];
      for (final p in patterns) {
        if (m.contains(p) || mo.contains(p) || b.contains(p)) {
          Logger.info(
              'Detected problematic device ($p) — will use native scanner');
          return true;
        }
      }
      return false;
    } catch (e) {
      Logger.warning('Error detecting device type: $e');
      return false;
    }
  }

  Future<bool> _shouldStopAdvertisingForScan() async {
    if (!Platform.isAndroid) return false;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return info.version.sdkInt >= 31;
    } catch (_) {
      return true;
    }
  }

  Future<int> _getScanDelayForDevice() async {
    if (!Platform.isAndroid) return 1000;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final m = info.manufacturer.toLowerCase();
      final mo = info.model.toLowerCase();
      final b = info.brand.toLowerCase();

      final isTecno = m.contains('tecno') ||
          mo.contains('tecno') ||
          b.contains('tecno') ||
          m.contains('transsion') ||
          mo.contains('cla') ||
          mo.contains('camon');
      if (isTecno) {
        Logger.info('Detected TECNO device — using 6000 ms delay');
        return 6000;
      }

      const problematic = [
        'infinix', 'itel', 'realme', 'oppo', 'vivo', 'xiaomi', 'redmi', 'poco'
      ];
      for (final brand in problematic) {
        if (m.contains(brand) || mo.contains(brand) || b.contains(brand)) {
          Logger.info('Detected $brand device — using 4000 ms delay');
          return 4000;
        }
      }
      return 2500;
    } catch (e) {
      Logger.warning('Error detecting device: $e');
      return 5000;
    }
  }

  Future<void> _restartAdvertisingAfterScan() async {
    try {
      Logger.info('ConnectionManager: resuming peripheral role after scan');
      await Future.delayed(const Duration(milliseconds: 500));

      final shouldResume = await _shouldStopAdvertisingForScan();
      if (shouldResume) {
        final resumed = await _blePeripheralService.resumeAfterScanning();
        if (!resumed) {
          Logger.error('Failed to resume GATT server');
          _peripheralInitialized = false;
        }
      }

      final deviceName = await _resolveDeviceName();
      final started = await _blePeripheralService.startAdvertising(
          deviceName: deviceName as String?);
      _isAdvertising = started;
      if (started) {
        Logger.info('Peripheral role resumed successfully');
      } else {
        Logger.warning('Failed to resume advertising');
      }
    } catch (e) {
      Logger.error('Error resuming peripheral role', e);
      _isAdvertising = false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Lifecycle
  // ═══════════════════════════════════════════════════════════════════

  void dispose() {
    _bleDiscoveryService.dispose();
    _wifiDirectService.dispose();
    _blePeripheralService.dispose();
    _bleDiscoverySubscription?.cancel();
    _nativeScanSubscription?.cancel();
    _peripheralConnectionStateSubscription?.cancel();
    _wifiConnectionStateSubscription?.cancel();
    _wifiIncomingMessagesSubscription?.cancel();
    _wifiInvitationSubscription?.cancel();
    _connectionController.close();
    _messageController.close();
    _deviceStreamController.close();
    _invitationController.close();
    _transportManager.dispose();
  }

  // ── Storage helper (inline, avoids extra import) ───────────────────
  final ScanLogStorage _scanLogStorage = ScanLogStorage.instance;
}
