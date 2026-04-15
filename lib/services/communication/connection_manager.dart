import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:device_info_plus/device_info_plus.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../models/message_model.dart';
import '../../models/message_packet.dart';
import '../../models/peer_connection_model.dart';
import '../../utils/logger.dart';
import '../../utils/permissions_helper.dart';
import '../storage/scan_log_storage.dart';
import '../storage/device_storage.dart';
import '../storage/pending_message_storage.dart';
import '../storage/known_contacts_storage.dart';
import '../routing/routing_manager.dart';
import '../mesh_handler.dart';
import '../peer_discovery.dart';
import '../dtn_retry_loop.dart';
import '../dtn_queue.dart';
import '../routing_engine.dart';
import '../presence_service.dart';
import 'transport_manager.dart';
import 'ble_discovery_service.dart';      // ← Control Plane (discovery only)
import 'ble_peripheral_service.dart';
import 'wifi_direct_service.dart';        // ← Data Plane (primary transport)
import '../group_session_manager.dart';   // ← Multi-GO group session state

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
  /// The connection was lost unexpectedly (e.g. moved out of range).
  /// The manager is automatically retrying until the peer comes back in range.
  /// Cleared automatically when the socket re-opens, or if the user taps
  /// a different device (which cancels the backoff loop).
  reconnecting,
}

class ConnectionManager {
  static final ConnectionManager _instance = ConnectionManager._internal();
  factory ConnectionManager() => _instance;

  ConnectionManager._internal() {
    // ── BLE Discovery → merge into device list ────────────────────
    _bleDiscoverySubscription =
        _bleDiscoveryService.discoveredDevices.listen((devices) {
      _bleDevices = devices;
      _emitDiscoveredDevices(); // auto-connect check is inside _emitDiscoveredDevices
    });

    // ── Native scan results (TECNO / problematic-device fallback) ──
    _nativeScanSubscription =
        _blePeripheralService.scanResults.listen(_handleNativeScanResult);

    // ── Broadcast delivery heartbeat ─────────────────────────────
    // Fires every 30 s regardless of BLE scan state.
    // Production logs show BLE scanning can silently fail, leaving queued
    // broadcasts undelivered until a manual WiFi Direct connection is made.
    // This timer is the fallback that guarantees delivery eventually fires.
    _broadcastHeartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_triggerBroadcastDelivery()),
    );
    // Also try immediately at startup (e.g. broadcasts queued in a previous
    // session) — give the stack 4 s to initialise first.
    Future.delayed(const Duration(seconds: 4),
        () => unawaited(_triggerBroadcastDelivery()));
  }

  // ── Services ──────────────────────────────────────────────────────
  final BleDiscoveryService _bleDiscoveryService = BleDiscoveryService();
  final BlePeripheralService _blePeripheralService = BlePeripheralService();
  final WifiDirectService _wifiDirectService = WifiDirectService();

  // ── Routing / Transport layers ────────────────────────────────────
  final RoutingManager _routingManager = RoutingManager();
  final TransportManager _transportManager = TransportManager();

  // ── DTN mesh layer ────────────────────────────────────────────────
  MeshHandler? _meshHandler;
  final PeerDiscovery _peerDiscovery = PeerDiscovery.instance;
  DtnRetryLoop? _dtnRetryLoop;
  StreamSubscription<String>? _meshDeliveredSubscription;

  // ── Multi-GO group session ─────────────────────────────────────────
  final GroupSessionManager _groupSession = GroupSessionManager();
  StreamSubscription<Map<String, dynamic>>? _groupMembersSubscription;

  /// Expose group session state to providers/UI.
  GroupSessionManager get groupSession => _groupSession;

  // ── State ─────────────────────────────────────────────────────────
  ConnectionType _currentConnectionType = ConnectionType.none;

  /// UUID of the currently connected peer (Wi-Fi Direct).
  String? _connectedPeerId;

  /// DeviceModel cached after a successful Wi-Fi Direct negotiation.
  DeviceModel? _connectedDevice;

  // ── Auto-reconnect state ──────────────────────────────────────────
  /// Last device we had a full SOCKET_CONNECTED session with.
  DeviceModel? _lastConnectedDevice;

  bool _userInitiatedDisconnect = false;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// Hard cap on auto-reconnect before giving up and showing an error.
  static const int _maxReconnectAttempts = 8;

  // ── Broadcast sequential-delivery state ──────────────────────────────────
  /// msgId → set of peerIds that have already received this broadcast in the
  /// current app session.  Prevents redundant re-sends and drives the delivery
  /// round (skip peers that already got every active broadcast).
  final Map<String, Set<String>> _broadcastDeliveredTo = {};

  /// Peers still waiting to receive the current batch of queued broadcasts.
  /// Populated by [_checkAndAutoConnectForPendingMessages]; consumed one at a
  /// time by [_scheduleNextBroadcastDelivery].
  final List<DeviceModel> _broadcastDeliveryQueue = [];

  /// True when the current WiFi-Direct connection was opened automatically
  /// by the broadcast delivery system, not by the user tapping a device.
  /// When true, [_scheduleNextBroadcastDelivery] will auto-disconnect and
  /// move to the next queued peer after [_syncPendingMessages] completes.
  bool _isAutoBroadcastConnection = false;

  // ── Broadcast delivery heartbeat ─────────────────────────────────────────
  /// Fires every 30 s regardless of BLE scan state.
  /// This is the safety-net: if BLE scanning fails (as observed in production)
  /// the app still attempts to deliver queued broadcasts to any known peers.
  // ignore: unused_field  — singleton; timer runs for the app lifetime.
  Timer? _broadcastHeartbeatTimer;

  bool get isReconnecting =>
      _reconnectTimer != null ||
      (_lastConnectedDevice != null && _reconnectAttempt > 0);

  // ── Connection timeout ────────────────────────────────────────────
  /// Fires if the TCP socket has not opened within [_connectionTimeoutSeconds].
  Timer? _connectionTimeoutTimer;

  /// Seconds before a pending connection attempt is abandoned automatically.
  static const int _connectionTimeoutSeconds = 30;

  /// Display name of the peer we are actively trying to connect to.
  /// Consumed by the UI to populate the "Connecting to …" stop-dialog.
  String? _connectingPeerName;
  String? get connectingPeerName => _connectingPeerName;

  /// Last human-readable failure reason.
  /// Read by [ConnectionNotifier] to surface descriptive error messages.
  String? _lastConnectionError;
  String? get lastConnectionError => _lastConnectionError;

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
  /// Peers discovered by Wi-Fi Direct background DNS-SD service browser.
  /// Keyed by UUID; populated independently of BLE, extending range to ~200 m.
  final Map<String, DeviceModel> _wifiDirectDiscoveredDevices = {};

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
  StreamSubscription<Map<String, dynamic>>? _deliveryAckSubscription;
  StreamSubscription<List<Map<String, dynamic>>>? _wifiDirectServicesSubscription;

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
      // Pass the device UUID so the native layer can register it as a
      // DNS-SD service immediately on start, making this device discoverable
      // by UUID before any explicit connect() call.
      final deviceUuid = DeviceStorage.getDeviceId();
      final wifiInitialized =
          await _wifiDirectService.initialize(deviceUuid: deviceUuid);

      // ── DTN Mesh layer ────────────────────────────────────────────
      final myUuid = DeviceStorage.getDeviceId();
      _meshHandler = MeshHandler(
        myUserId: myUuid,
        sendViaTransport: (wireData) => _wifiDirectService.sendMessage(wireData),
        // Broadcasts go to EVERY neighbour registered in TransportManager.
        // TransportManager.broadcastToAllPeers() iterates its neighbour map
        // and calls sendToPeer() for each — returns count of successful sends.
        broadcastViaTransport: (wireData) async {
          final bytes = Uint8List.fromList(utf8.encode(wireData));
          return _transportManager.broadcastToAllPeers(bytes);
        },
      );

      // Delivered packets (converted to MessageModel JSON) → UI pipeline
      _meshDeliveredSubscription?.cancel();
      _meshDeliveredSubscription =
          _meshHandler!.deliveredMessages.listen((json) {
        _messageController.add(json);
      });

      // Route advert on every new peer connection
      _peerDiscovery.onPeerAdded = (peer) {
        unawaited(_meshHandler!.sendRouteAdvert(peer));
      };

      // Start background DTN retry loop
      _dtnRetryLoop = DtnRetryLoop(meshHandler: _meshHandler!);
      _dtnRetryLoop!.start();

      // ── RoutingManager: locally delivered messages ────────────────
      _routingManager.localMessages.listen((message) {
        Logger.info(
            'RoutingManager: locally delivered message for ${message.finalReceiverId}');
        _messageController.add(jsonEncode(message.toJson()));
      });

      // ── RoutingManager: delivery ACKs → send back to peer ─────────
      _deliveryAckSubscription?.cancel();
      _deliveryAckSubscription =
          _routingManager.deliveryAcks.listen((ack) {
        Logger.info(
            'ConnectionManager: forwarding delivery ACK for '
            'messageId=${ack['messageId']} back to peer');
        final ackJson = jsonEncode(ack);
        unawaited(_wifiDirectService.sendMessage(ackJson));
      });

      // ── Wi-Fi Direct: incoming messages ──────────────────────────
      _wifiIncomingMessagesSubscription?.cancel();
      _wifiIncomingMessagesSubscription =
          _wifiDirectService.incomingMessages.listen((message) {
        Logger.info('ConnectionManager: message received via Wi-Fi Direct');
        _handleIncomingMessage(message);
      });

      // Wi-Fi Direct connection state is wired below together with
      // Multi-GO group session sync (see further down in initialize()).

      // ── Wi-Fi Direct: incoming invitations ────────────────────────
      _wifiInvitationSubscription?.cancel();
      _wifiInvitationSubscription =
          _wifiDirectService.incomingInvitations.listen((payload) {
        Logger.info(
            'ConnectionManager: incoming invitation from ${payload["deviceName"]}');
        _invitationController.add(payload);
      });

      // ── Wi-Fi Direct: background DNS-SD discovered services ───────
      // Peers found at Wi-Fi Direct range (~200 m), independent of BLE.
      // We surface any entry that has a known display name (from DeviceStorage
      // or from the DNS-SD TXT record) so the UI shows them alongside BLE peers.
      _wifiDirectServicesSubscription?.cancel();
      _wifiDirectServicesSubscription =
          _wifiDirectService.discoveredServices.listen((services) {
        bool changed = false;
        for (final svc in services) {
          final uuid = svc['uuid'] as String?;
          if (uuid == null || uuid.isEmpty) continue;
          // Skip ourselves
          if (uuid == DeviceStorage.getDeviceId()) continue;

          // Resolve display name: TXT record name → stored name → skip
          final txtName = svc['name'] as String?;
          final storedName = DeviceStorage.getDeviceDisplayName(uuid);
          final displayName = (storedName?.isNotEmpty == true)
              ? storedName!
              : (txtName?.isNotEmpty == true ? txtName! : null);

          if (displayName == null) continue; // no usable name yet

          // Store the name for future sessions if we got it from DNS-SD
          if (storedName == null && txtName != null && txtName.isNotEmpty) {
            unawaited(DeviceStorage.setDeviceDisplayName(uuid, txtName));
          }

          final device = DeviceModel(
            id: uuid,
            name: displayName,
            type: DeviceType.wifiDirect,
            isConnected: false,
          );
          _wifiDirectDiscoveredDevices[uuid] = device;
          changed = true;
        }
        if (changed) _emitDiscoveredDevices();
      });

      // ── Multi-GO group member events ─────────────────────────────
      _groupMembersSubscription?.cancel();
      _groupMembersSubscription =
          _wifiDirectService.groupMemberEvents.listen((event) {
        _groupSession.handleNativeMemberEvent(event);
        // Emit connection-state change so providers rebuild the member list
        _connectionController
            .add(ConnectionState.connected); // re-use existing event
      });

      // ── Wi-Fi Direct: connection state + Multi-GO group session sync ─────
      _wifiConnectionStateSubscription?.cancel();
      _wifiConnectionStateSubscription =
          _wifiDirectService.connectionState.listen((state) {
        if (state.isGroupOwner && state.socketActive) {
          final myId = DeviceStorage.getDeviceId();
          if (!_groupSession.isGroupOwner) {
            _groupSession.becomeGroupOwner(
              myId: myId,
              groupId: '${myId}_${DateTime.now().millisecondsSinceEpoch}',
            );
          }
        } else if (!state.connected && _groupSession.isInGroup) {
          _groupSession.leaveGroup();
        }
        _handleWifiDirectState(state);
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
        // Start presence tracking for saved contacts (Feature 4)
        unawaited(_startPresenceTracking());
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
        // Cancel the 30-second watchdog — we made it in time.
        _cancelConnectionTimeout();
        _connectingPeerName = null;

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
          // Successful session — save for auto-reconnect and reset counter.
          _lastConnectedDevice = device;
          _cancelReconnect();
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

          // Remove from DTN peer discovery
          if (_connectedPeerId != null) {
            _peerDiscovery.removePeer(_connectedPeerId!);
            // Stamp lastSeen so contact book shows accurate "last seen X ago"
            unawaited(KnownContactsStorage.updateLastSeen(_connectedPeerId!));
          }

          _currentConnectionType = ConnectionType.none;
          _connectedDevice = null;
          _connectedPeerId = null;

          if (_userInitiatedDisconnect) {
            // ── User tapped Disconnect — no auto-reconnect ──────────────
            _userInitiatedDisconnect = false;
            _connectionController.add(ConnectionState.disconnected);
          } else if (_lastConnectedDevice != null) {
            // ── Unexpected drop (range / signal) — auto-reconnect ────────
            Logger.info(
                'ConnectionManager: unexpected disconnect from '
                '"${_lastConnectedDevice!.name}" — '
                'entering auto-reconnect (attempt ${_reconnectAttempt + 1})…');
            _connectionController.add(ConnectionState.reconnecting);
            _scheduleReconnect();
          } else {
            // ── Never had a full session (initial connect failed) ─────────
            if (state.error != null) {
              _connectionController.add(ConnectionState.error);
            } else {
              _connectionController.add(ConnectionState.disconnected);
            }
          }
        }
      }
    } catch (e, st) {
      Logger.error('ConnectionManager: error handling Wi-Fi Direct state', e, st);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // UUID Handshake — mutual UUID exchange over the socket
  // ═══════════════════════════════════════════════════════════════════

  /// Sends our UUID and display name to the peer immediately after the socket opens.
  /// Both sides do this so neither needs to know the other's UUID or name in advance.
  void _sendUuidHandshake() {
    try {
      final myUuid = DeviceStorage.getDeviceId();
      final myName = DeviceStorage.getDisplayName() ?? '';
      final handshake = jsonEncode({
        '__type': '__uuid_handshake__',
        'senderUuid': myUuid,
        'senderName': myName,
      });
      // Use the service directly — transport map may still be placeholder.
      _wifiDirectService.sendMessage(handshake);
      Logger.info('ConnectionManager: 🤝 sent UUID handshake (myUuid=$myUuid, myName=$myName)');
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

        // Prefer the name sent in the handshake; fall back to stored BLE name.
        final handshakeName = (handshake['senderName'] as String?)?.trim();
        final peerName = (handshakeName != null && handshakeName.isNotEmpty)
            ? handshakeName
            : (DeviceStorage.getDeviceDisplayName(senderUuid) ?? 'Offlink Peer');

        // Persist so future lookups (after reconnect) also use the correct name,
        // and refresh the in-memory discovery cache so the home screen updates.
        if (handshakeName != null && handshakeName.isNotEmpty) {
          unawaited(DeviceStorage.setDeviceDisplayName(senderUuid, handshakeName));
          _refreshDeviceNameInCache(senderUuid, handshakeName);
        }

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
        // Successful session (receiver side) — save for auto-reconnect.
        _lastConnectedDevice = device;
        _cancelReconnect();
        _connectionController.add(ConnectionState.connected);

        Logger.info(
            'ConnectionManager: ✅ peer UUID resolved from handshake — '
            'peerId=$senderUuid, name=$peerName');

        // Save as a known contact so they appear in the contacts list
        unawaited(KnownContactsStorage.saveContact(
          peerId: senderUuid,
          displayName: peerName,
        ));

        // Register in DTN peer discovery (triggers route advert)
        final ipAddr = lastState.ipAddress ?? senderUuid;
        _peerDiscovery.addPeer(PeerInfo(
          userId: senderUuid,
          address: ipAddr,
          transport: 'wifi_direct',
        ));

        // Flush any pending messages for this peer, then advance the
        // broadcast delivery queue (connects to next peer if needed).
        _syncPendingMessages(senderUuid).then((_) {
          _scheduleNextBroadcastDelivery(senderUuid);
        }).catchError((Object e) {
          Logger.error('ConnectionManager: _syncPendingMessages error', e);
        });
      } else {
        // ── INITIATOR side: handshake reply confirms peer is ready ──
        // Also update the peer's name if the handshake carries a better one.
        const _handshakePlaceholders = {'', 'Offlink Peer', 'Connecting…'};
        final handshakeName = (handshake['senderName'] as String?)?.trim();
        if (handshakeName != null && handshakeName.isNotEmpty) {
          unawaited(DeviceStorage.setDeviceDisplayName(_connectedPeerId!, handshakeName));
          _refreshDeviceNameInCache(_connectedPeerId!, handshakeName);
          if (_connectedDevice != null &&
              _handshakePlaceholders.contains(_connectedDevice!.name)) {
            _connectedDevice = _connectedDevice!.copyWith(name: handshakeName);
            _lastConnectedDevice = _connectedDevice;
          }
        }

        Logger.info(
            'ConnectionManager: peer confirmed UUID handshake '
            '(our _connectedPeerId=${_connectedPeerId!})');

        // Register in DTN peer discovery (triggers route advert)
        final lastState2 = _wifiDirectService.lastKnownState;
        final ipAddr2 = lastState2.ipAddress ?? _connectedPeerId!;
        _peerDiscovery.addPeer(PeerInfo(
          userId: _connectedPeerId!,
          address: ipAddr2,
          transport: 'wifi_direct',
        ));

        // Flush pending messages now that the socket is confirmed open,
        // then advance the broadcast delivery queue if applicable.
        final peerId = _connectedPeerId!;
        _syncPendingMessages(peerId).then((_) {
          _scheduleNextBroadcastDelivery(peerId);
        }).catchError((Object e) {
          Logger.error('ConnectionManager: _syncPendingMessages error', e);
        });
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
      // ── Guard: connected to a DIFFERENT peer — disconnect first ───────
      // Android Wi-Fi Direct supports only one active P2P group at a time.
      // When the Kotlin layer is in SOCKET_CONNECTED state, connectToPeer()
      // returns {"duplicate": true} without invoking WifiP2pManager.connect(),
      // so the new peer never receives an invitation.
      //
      // Fix: tear down the current link before starting the new negotiation.
      // We send a graceful-disconnect frame so the old peer suppresses its
      // auto-reconnect, wait for the group to dissolve (1.5 s), then proceed.
      if (isConnected() && _connectedPeerId != null && _connectedPeerId != device.id) {
        Logger.info(
            'ConnectionManager: switching peer — disconnecting from '
            '"${_connectedDevice?.name ?? _connectedPeerId}" '
            'before connecting to "${device.name}"');
        await _sendGracefulDisconnect();
        _userInitiatedDisconnect = true;
        _lastConnectedDevice = null;  // suppress auto-reconnect to old peer
        _cancelReconnect();
        await _wifiDirectService.disconnect();
        if (_connectedPeerId != null) {
          _transportManager.removeNeighbor(_connectedPeerId!);
          _peerDiscovery.removePeer(_connectedPeerId!);
          unawaited(KnownContactsStorage.updateLastSeen(_connectedPeerId!));
        }
        _currentConnectionType = ConnectionType.none;
        _connectedDevice = null;
        _connectedPeerId = null;
        // Give Android time to fully dissolve the P2P group before we
        // request a new one; without this the new connect() call races
        // with the teardown broadcast and is silently ignored.
        await Future.delayed(const Duration(milliseconds: 1500));
      }

      // ── Guard: already connected to the same peer ─────────────────
      // This can happen when the native layer reconnects passively BEFORE
      // the Dart-side reconnect timer or the chat-screen "Reconnect" button
      // fires connectToDevice.  If we let it proceed, line 778 would emit
      // ConnectionState.connecting; Kotlin would return "already connected"
      // without generating a new connection event, leaving the UI stuck at
      // "connecting" indefinitely.
      if (isConnected() && _connectedPeerId == device.id) {
        Logger.info(
            'ConnectionManager: already connected to "${device.name}" '
            '— skipping connectToDevice, re-asserting connected state');
        _connectionController.add(ConnectionState.connected);
        return true;
      }

      // Stop BLE scan to free radio resources (Wi-Fi Direct also needs them)
      Logger.info(
          'ConnectionManager: stopping BLE scan before Wi-Fi Direct connect');
      try {
        await stopScan();
        await Future.delayed(const Duration(milliseconds: 500));
      } catch (e) {
        Logger.warning('Error stopping scan before connect: $e');
      }

      // If connecting to a different device, cancel any pending auto-reconnect.
      if (_lastConnectedDevice != null && _lastConnectedDevice!.id != device.id) {
        Logger.info(
            'ConnectionManager: connecting to new device "${device.name}" — '
            'cancelling auto-reconnect for "${_lastConnectedDevice!.name}"');
        _lastConnectedDevice = null;
        _cancelReconnect();
      }

      _connectingPeerName = device.name;
      _lastConnectionError = null;
      _connectionController.add(ConnectionState.connecting);
      Logger.info(
          'ConnectionManager: initiating Wi-Fi Direct connection to "${device.name}"');

      // Start watchdog: if socket is not open within 30 s, emit error.
      _startConnectionTimeout(device.name);

      // Store the peer UUID — this is the single authoritative identity key.
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
      // UUID is the ONLY identity used here. The native layer resolves
      // UUID → MAC internally via DNS-SD service discovery.
      // MAC addresses NEVER appear in the Dart layer.
      Logger.info(
          'ConnectionManager: initiating Wi-Fi Direct to '
          '"${device.name}" (UUID=${device.id})');
      final result = await _wifiDirectService.initiateConnection(
          targetUuid: device.id, targetName: device.name);

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

  /// Send a graceful disconnect notification to the peer so they suppress
  /// auto-reconnect on their side.
  Future<void> _sendGracefulDisconnect() async {
    if (_connectedPeerId == null) return;
    try {
      final msg = jsonEncode({'__type': '__graceful_disconnect__'});
      await _wifiDirectService.sendMessage(msg);
      // Small delay so the frame can flush before socket closes
      await Future.delayed(const Duration(milliseconds: 150));
    } catch (_) {
      // Best-effort — ignore errors, we're disconnecting anyway
    }
  }

  /// Disconnect from the current Wi-Fi Direct peer.
  Future<void> disconnect() async {
    try {
      // Send graceful notice FIRST so the peer suppresses auto-reconnect.
      await _sendGracefulDisconnect();

      // Mark as user-initiated BEFORE calling the native layer so that the
      // resulting CONNECTION_CHANGED broadcast doesn't trigger auto-reconnect.
      _userInitiatedDisconnect = true;
      _lastConnectedDevice = null;
      _cancelReconnect();

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
  // Auto-reconnect
  // ═══════════════════════════════════════════════════════════════════

  /// Schedule the next reconnect attempt using exponential back-off.
  /// Delays: 5s → 10s → 15s … capped at 60s per attempt.
  ///
  /// UUID tiebreaker: when both peers lose the connection simultaneously, both
  /// schedule a reconnect. If both fire `connect()` at the same time, Android's
  /// Wi-Fi Direct group-owner negotiation deadlocks (5× CONNECTING timeouts).
  /// To break the symmetry, the device whose UUID is lexicographically SMALLER
  /// than the peer's UUID waits an extra 8 s. This consistently makes the
  /// "larger UUID" device initiate, and the "smaller UUID" device receives the
  /// incoming invitation passively — avoiding the collision.
  void _scheduleReconnect() {
    if (_reconnectTimer != null) {
      Logger.info('ConnectionManager: reconnect already scheduled — ignoring duplicate trigger');
      return;
    }

    // ── Hard limit: give up after _maxReconnectAttempts ───────────────
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      Logger.warning(
          'ConnectionManager: reached max reconnect attempts ($_maxReconnectAttempts) '
          '— giving up on "${_lastConnectedDevice?.name}"');
      _lastConnectionError =
          'Could not reconnect to "${_lastConnectedDevice?.name}" '
          'after $_maxReconnectAttempts attempts.';
      _lastConnectedDevice = null;
      _reconnectAttempt = 0;
      _connectionController.add(ConnectionState.error);
      return;
    }

    _reconnectAttempt++;
    final baseDelay = (_reconnectAttempt * 5).clamp(5, 60);
    final myUuid   = DeviceStorage.getDeviceId();
    final peerUuid = _lastConnectedDevice?.id ?? '';
    // If we are the "smaller" peer, wait longer so the "larger" peer always
    // initiates first. The extra delay must exceed the Kotlin CONNECTING timeout
    // (15 s) to allow the first-initiator's attempt to either succeed or fail
    // cleanly before we start our own attempt.
    final extraDelay = (peerUuid.isNotEmpty && myUuid.compareTo(peerUuid) < 0) ? 16 : 0;
    final delaySeconds = baseDelay + extraDelay;
    Logger.info(
        'ConnectionManager: auto-reconnect #$_reconnectAttempt '
        'scheduled in ${delaySeconds}s (base=$baseDelay extra=$extraDelay) '
        '→ "${_lastConnectedDevice?.name}"');
    _reconnectTimer = Timer(Duration(seconds: delaySeconds), () async {
      _reconnectTimer = null;
      final target = _lastConnectedDevice;
      if (target == null) return; // user disconnected or switched peer

      // The native layer may have already passively reconnected while we were
      // waiting (e.g. the peer invited us before the timer fired).  In that
      // case, abort the active-reconnect attempt and just reset the counter.
      if (isConnected()) {
        Logger.info(
            'ConnectionManager: auto-reconnect #$_reconnectAttempt timer fired '
            'but native layer already reconnected — resetting counter');
        _reconnectAttempt = 0;
        return;
      }

      Logger.info(
          'ConnectionManager: auto-reconnect #$_reconnectAttempt '
          '— dialling "${target.name}"…');
      final success = await connectToDevice(target);
      // connectToDevice emits connecting/connected states itself.
      // If it fails synchronously the state handler will retry via _scheduleReconnect.
      if (!success && _lastConnectedDevice != null) {
        _scheduleReconnect();
      }
    });
  }

  /// Cancel any pending reconnect timer and reset the attempt counter.
  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
  }

  // ═══════════════════════════════════════════════════════════════════
  // Connection timeout
  // ═══════════════════════════════════════════════════════════════════

  /// Start a [_connectionTimeoutSeconds]-second watchdog timer.
  /// If the TCP socket is not open by the time it fires, we emit an error
  /// and clean up — preventing the UI from spinning forever.
  void _startConnectionTimeout(String peerName) {
    _cancelConnectionTimeout();
    _connectionTimeoutTimer =
        Timer(const Duration(seconds: _connectionTimeoutSeconds), () {
      if (!isConnected()) {
        Logger.warning(
            'ConnectionManager: connection to "$peerName" timed out '
            'after ${_connectionTimeoutSeconds}s');
        _lastConnectionError =
            'Connection to "$peerName" timed out. '
            'Make sure both devices have Wi-Fi Direct enabled and are in range.';
        _cancelConnectionTimeout();
        _cancelReconnect();
        _userInitiatedDisconnect = true; // suppress auto-reconnect on this timeout
        _wifiDirectService.disconnect();
        final idToRemove = _connectedPeerId ?? '__uuid_pending__';
        _transportManager.removeNeighbor(idToRemove);
        if (_connectedPeerId != null) _peerDiscovery.removePeer(_connectedPeerId!);
        _currentConnectionType = ConnectionType.none;
        _connectedDevice = null;
        _connectedPeerId = null;
        _connectingPeerName = null;
        _lastConnectedDevice = null; // prevent auto-reconnect after timeout
        _connectionController.add(ConnectionState.error);
      }
    });
  }

  void _cancelConnectionTimeout() {
    _connectionTimeoutTimer?.cancel();
    _connectionTimeoutTimer = null;
  }

  // ═══════════════════════════════════════════════════════════════════
  // User-initiated cancel (mid-connecting Stop button)
  // ═══════════════════════════════════════════════════════════════════

  /// Cancel any in-progress connection attempt.
  /// Called when the user taps "Stop Connecting" in the UI.
  Future<void> cancelConnection() async {
    try {
      Logger.info('ConnectionManager: connection cancelled by user');
      _cancelConnectionTimeout();
      _cancelReconnect();
      await _sendGracefulDisconnect();
      _userInitiatedDisconnect = true;
      _lastConnectionError = null;
      _connectingPeerName = null;
      await _wifiDirectService.disconnect();
      final idToRemove = _connectedPeerId ?? '__uuid_pending__';
      _transportManager.removeNeighbor(idToRemove);
      if (_connectedPeerId != null) _peerDiscovery.removePeer(_connectedPeerId!);
      _currentConnectionType = ConnectionType.none;
      _connectedDevice = null;
      _connectedPeerId = null;
      _lastConnectedDevice = null; // don't auto-reconnect after a cancel
      _connectionController.add(ConnectionState.disconnected);
    } catch (e) {
      Logger.error('ConnectionManager: cancelConnection error', e);
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

  Future<void> _handleIncomingMessage(String message) async {
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
        return;
      }

      // ── Graceful disconnect — peer is intentionally closing ───────
      // Suppress auto-reconnect so we don't keep pestering the peer.
      if (jsonMap['__type'] == '__graceful_disconnect__') {
        Logger.info('ConnectionManager: peer sent graceful disconnect — suppressing auto-reconnect');
        _userInitiatedDisconnect = true;
        _lastConnectedDevice = null;
        _cancelReconnect();
        return;
      }

      // ── Delivery ACK (legacy path) — intercept before routing ─────
      if (jsonMap['__type'] == '__delivery_ack__') {
        _handleDeliveryAck(jsonMap);
        return;
      }

      // ── MessagePacket (DTN format) → MeshHandler ──────────────────
      // Detect by presence of 'msgId' + 'toUserId' + 'ttl' + 'type' fields.
      if (MessagePacket.looksLikePacket(jsonMap)) {
        try {
          await _meshHandler?.onRawReceived(
            message,
            currentPeers: _peerDiscovery.currentPeers,
          );
        } catch (e, st) {
          Logger.error('ConnectionManager: MeshHandler.onRawReceived failed', e, st);
        }
        return;
      }

      // ── Legacy MessageModel format → RoutingManager ───────────────
      final messageModel = MessageModel.fromJson(jsonMap);
      try {
        await _routingManager.routeMessage(
          messageModel,
          senderPeerId: _connectedPeerId,
        );
      } catch (e, st) {
        Logger.error('ConnectionManager: RoutingManager.routeMessage failed', e, st);
      }
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

  // ═══════════════════════════════════════════════════════════════════
  // DTN routing — send a MessagePacket through the mesh layer
  // ═══════════════════════════════════════════════════════════════════

  /// Route a new outbound [MessagePacket] created by the local user.
  ///
  /// Uses [MeshHandler] + [RoutingEngine] to decide: direct send, relay,
  /// or buffer in [DtnQueue] for when a peer comes into range.
  ///
  /// Returns true if sent over the air now; false if queued in DTN.
  Future<bool> routePacket(MessagePacket packet) async {
    if (_meshHandler == null) {
      Logger.warning('ConnectionManager: MeshHandler not ready — cannot route packet');
      return false;
    }
    return await _meshHandler!.sendMessage(
      packet: packet,
      currentPeers: _peerDiscovery.currentPeers,
    );
  }

  Stream<List<DeviceModel>> getDiscoveredDevices() =>
      _deviceStreamController.stream;

  // ═══════════════════════════════════════════════════════════════════
  // Multi-GO Broadcast Group API
  // ═══════════════════════════════════════════════════════════════════

  /// Start this device as the Multi-GO Group Owner.
  ///
  /// This calls [WifiDirectService.startAsGroupOwner()] which triggers
  /// [WifiP2pManager.createGroup()] on the native side with GO intent = 15,
  /// then opens the multi-client TCP ServerSocket.
  ///
  /// On success [groupSession.isGroupOwner] becomes true and subsequent
  /// broadcast sends use [_transportManager.sendToAllClients] instead of
  /// the sequential DTN epidemic path.
  ///
  /// Returns true if the native call was accepted.
  Future<bool> startBroadcastGroup() async {
    if (!_isInitialized) return false;
    final result = await _wifiDirectService.startAsGroupOwner();
    if (result['success'] == true) {
      Logger.info('[ConnectionManager] startBroadcastGroup: GO role requested');
      return true;
    }
    Logger.error('[ConnectionManager] startBroadcastGroup failed: ${result['error']}');
    return false;
  }

  /// Join an existing Multi-GO broadcast group as a client.
  ///
  /// [groupOwnerDevice] — the Group Owner's [DeviceModel] (from BLE/DNS-SD discovery).
  ///
  /// Connects via the standard UUID-based Wi-Fi Direct path; after the
  /// TCP socket is established the device can send to the GO via
  /// [_transportManager.sendToGroupOwner] and receives all broadcasts
  /// the GO relays.
  ///
  /// Returns true if the connection attempt was initiated.
  Future<bool> joinBroadcastGroup(DeviceModel groupOwnerDevice) async {
    if (!_isInitialized) return false;
    final result = await _wifiDirectService.joinGroupAsClient(
      targetUuid: groupOwnerDevice.id,
      targetName: groupOwnerDevice.name,
    );
    if (result['success'] == true) {
      _groupSession.joinGroup(
        ownerId: groupOwnerDevice.id,
        groupId: groupOwnerDevice.id,
      );
      Logger.info('[ConnectionManager] joinBroadcastGroup: connecting to GO ${groupOwnerDevice.id}');
      return true;
    }
    Logger.error('[ConnectionManager] joinBroadcastGroup failed: ${result['error']}');
    return false;
  }

  /// Route a broadcast packet using the best available path:
  ///   - GO mode  → [sendToAllClients] (simultaneous, milliseconds)
  ///   - Client   → [sendToGroupOwner] (GO relays to everyone)
  ///   - No group → existing DTN epidemic path (kept as fallback)
  Future<bool> routeBroadcastPacket(MessagePacket packet,
      {String? senderUuid}) async {
    if (_groupSession.isGroupOwner) {
      final wireData = packet.toWire();
      final count = await _transportManager.sendToAllClients(
        wireData,
        senderUuid: senderUuid,
      );
      Logger.info('[ConnectionManager] routeBroadcastPacket: GO → sent to $count clients');
      return count > 0;
    } else if (_groupSession.isInGroup) {
      final wireData = packet.toWire();
      final ok = await _transportManager.sendToGroupOwner(wireData);
      Logger.info('[ConnectionManager] routeBroadcastPacket: client → sent to GO: $ok');
      return ok;
    }
    // Fallback: DTN epidemic flooding (existing behaviour)
    return routePacket(packet);
  }

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

      const _nativeScanPlaceholders = {
        'Unknown Device', 'Unknown', 'Offlink Peer', 'Connecting…'
      };

      final storedName =
          DeviceStorage.getDeviceDisplayName(finalDeviceId);

      // A "fresh" name is one from the BLE advertisement that is neither a
      // placeholder nor the raw device/MAC identifier.
      final hasFreshName = deviceName.isNotEmpty &&
          !_nativeScanPlaceholders.contains(deviceName) &&
          deviceName != finalDeviceId &&
          deviceName != macAddress;

      String displayName;
      if (hasFreshName) {
        displayName = deviceName;
        // Persist if the stored name is absent or is a stale placeholder.
        if (deviceUuid != null &&
            finalDeviceId == deviceUuid &&
            !finalDeviceId.contains(':') &&
            (storedName == null || _nativeScanPlaceholders.contains(storedName))) {
          unawaited(
              DeviceStorage.setDeviceDisplayName(finalDeviceId, deviceName));
          Logger.info(
              'Native scan: storing/updating device name '
              '$finalDeviceId → $deviceName');
        }
      } else if (storedName != null &&
          !_nativeScanPlaceholders.contains(storedName)) {
        displayName = storedName;
      } else {
        displayName = deviceName.isNotEmpty ? deviceName : 'Unknown Device';
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
      // Embed our username in the Wi-Fi Direct DNS-SD TXT record so peers
      // can display our name when discovered at Wi-Fi Direct range (~200 m).
      if (deviceName is String && deviceName.isNotEmpty) {
        unawaited(_wifiDirectService.setOwnUsername(deviceName));
      }
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
    // Wi-Fi Direct background DNS-SD discoveries (lowest priority — no RSSI)
    for (final d in _wifiDirectDiscoveredDevices.values) {
      combined[d.id] = d;
    }
    // BLE discoveries override (have RSSI, fresher signal info)
    for (final d in _bleDevices) {
      combined[d.id] = d;
    }
    // Native-scan devices take highest priority (freshest RSSI / most metadata)
    for (final d in _nativeScanDevices.values) {
      combined[d.id] = d;
    }
    final deviceList = combined.values.toList();
    _deviceStreamController.add(deviceList);

    // Trigger broadcast (and unicast) auto-connect whenever ANY discovery
    // source updates the device list — BLE, WiFi Direct DNS-SD, or native scan.
    // Previously this only fired from the BLE subscription, so WiFi Direct
    // DNS-SD discoveries (which work even when BLE scanning fails) were ignored.
    if (deviceList.isNotEmpty) {
      unawaited(_checkAndAutoConnectForPendingMessages(deviceList));
    }
  }

  /// Build the current combined device list from all discovery sources and
  /// call [_checkAndAutoConnectForPendingMessages].
  ///
  /// Called by the 30-second heartbeat timer so that queued broadcasts are
  /// delivered even when BLE scanning has silently stopped.
  Future<void> _triggerBroadcastDelivery() async {
    final Map<String, DeviceModel> combined = {};
    for (final d in _wifiDirectDiscoveredDevices.values) combined[d.id] = d;
    for (final d in _bleDevices) combined[d.id] = d;
    for (final d in _nativeScanDevices.values) combined[d.id] = d;
    final deviceList = combined.values.toList();
    if (deviceList.isNotEmpty) {
      await _checkAndAutoConnectForPendingMessages(deviceList);
    }
  }

  /// Update the cached name for [uuid] across all in-memory device maps and
  /// re-emit the device list so the home screen reflects the correct name
  /// immediately (e.g. right after a UUID handshake resolves the peer name).
  void _refreshDeviceNameInCache(String uuid, String name) {
    if (name.isEmpty) return;
    bool changed = false;

    final nativeEntry = _nativeScanDevices[uuid];
    if (nativeEntry != null && nativeEntry.name != name) {
      _nativeScanDevices[uuid] = nativeEntry.copyWith(name: name);
      changed = true;
    }

    final wdEntry = _wifiDirectDiscoveredDevices[uuid];
    if (wdEntry != null && wdEntry.name != name) {
      _wifiDirectDiscoveredDevices[uuid] = wdEntry.copyWith(name: name);
      changed = true;
    }

    final bleIdx = _bleDevices.indexWhere((d) => d.id == uuid);
    if (bleIdx >= 0 && _bleDevices[bleIdx].name != name) {
      final updated = List<DeviceModel>.from(_bleDevices);
      updated[bleIdx] = _bleDevices[bleIdx].copyWith(name: name);
      _bleDevices = updated;
      changed = true;
    }

    if (changed) _emitDiscoveredDevices();
  }

  // ═══════════════════════════════════════════════════════════════════
  // Device-specific scan helpers
  // ═══════════════════════════════════════════════════════════════════

  Future<bool> _shouldUseNativeScanner() async {
    if (!Platform.isAndroid) return false;
    // Always prefer the native BLE scanner on Android.
    //
    // Reasons:
    //  1. flutter_blue_plus (FBP) only exposes manufacturer data from the
    //     PRIMARY advertisement in advertisementData.manufacturerData.
    //     Scan-response manufacturer data (key 0xFFFE, which carries the
    //     username) is NOT reliably surfaced by FBP on many devices.
    //  2. On some Samsung / OEM devices, the FBP scan registers but then
    //     terminates in milliseconds (hardware/firmware quirk), giving no
    //     useful scan window.
    //
    // The native scanner reads Android's merged ScanRecord directly via
    // getManufacturerSpecificData(0xFFFE), which works on all tested
    // devices. FBP (BleDiscoveryService) is kept as the fallback for
    // devices where the native scanner registration itself fails.
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      Logger.info(
          'Device: manufacturer=${info.manufacturer}, '
          'model=${info.model}, brand=${info.brand} — '
          'using native BLE scanner');
    } catch (_) {}
    return true;
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
    _dtnRetryLoop?.stop();
    _meshDeliveredSubscription?.cancel();
    _meshHandler?.dispose();
    _bleDiscoveryService.dispose();
    _wifiDirectService.dispose();
    _blePeripheralService.dispose();
    _bleDiscoverySubscription?.cancel();
    _nativeScanSubscription?.cancel();
    _peripheralConnectionStateSubscription?.cancel();
    _wifiConnectionStateSubscription?.cancel();
    _wifiIncomingMessagesSubscription?.cancel();
    _wifiInvitationSubscription?.cancel();
    _deliveryAckSubscription?.cancel();
    _connectionController.close();
    _messageController.close();
    _deviceStreamController.close();
    _invitationController.close();
    _transportManager.dispose();
    _peerDiscovery.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════
  // Delivery ACK handler
  // ═══════════════════════════════════════════════════════════════════

  /// Called when a `__delivery_ack__` packet arrives from the peer.
  ///
  /// Removes the confirmed message from the pending queue and emits
  /// the ACK on [incomingMessages] so [ConnectionNotifier] can update
  /// the message status in storage and the chat UI.
  void _handleDeliveryAck(Map<String, dynamic> ack) {
    try {
      final messageId = ack['messageId'] as String?;
      if (messageId == null) return;

      Logger.info(
          'ConnectionManager: 📬 received delivery ACK for messageId=$messageId');

      // Remove from pending queue — delivery confirmed
      unawaited(PendingMessageStorage.removePendingMessage(messageId));

      // Emit as a special JSON string so ConnectionNotifier can update UI
      _messageController.add(jsonEncode(ack));
    } catch (e) {
      Logger.error('ConnectionManager: error handling delivery ACK', e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Store-and-Forward: sync pending messages when a peer connects
  // ═══════════════════════════════════════════════════════════════════

  /// Flush pending messages to a newly connected peer.
  ///
  /// Only sends messages destined for [connectedPeerId] (direct delivery)
  /// or messages that need relay via this peer. Does NOT send all buffered
  /// messages to every peer — that was a privacy leak.
  ///
  /// Uses the DTN queue (DtnQueue) as the single source of truth for
  /// buffered messages. PendingMessageStorage (Hive) is the legacy path.
  Future<void> _syncPendingMessages(String connectedPeerId) async {
    // ── Primary path: DtnQueue (SQLite) ───────────────────────────
    final dtnPending = await DtnQueue.getPendingPackets();

    // ── Broadcast packets (toUserId == '*') ───────────────────────
    // Fetch with NO throttle — every peer that connects must receive all
    // active broadcasts regardless of when another peer was last served.
    // We do NOT delete them from the queue here; [recordBroadcastSent]
    // only updates last_attempt so other peers can still receive them.
    final broadcastPkts = await DtnQueue.getPendingBroadcasts();
    if (broadcastPkts.isNotEmpty) {
      Logger.info(
          'ConnectionManager: flushing ${broadcastPkts.length} broadcast '
          'packet(s) to newly connected peer $connectedPeerId');
      int bSynced = 0;
      for (final packet in broadcastPkts) {
        // Skip if already delivered to this peer this session.
        final alreadySent =
            _broadcastDeliveredTo[packet.msgId]?.contains(connectedPeerId) ??
                false;
        if (alreadySent) {
          Logger.debug(
              'ConnectionManager: broadcast ${packet.msgId} already '
              'delivered to $connectedPeerId — skipping');
          continue;
        }
        try {
          final sent = await _wifiDirectService.sendMessage(packet.toWire());
          if (sent) {
            bSynced++;
            // Track in-memory: this peer got the broadcast.
            _broadcastDeliveredTo
                .putIfAbsent(packet.msgId, () => {})
                .add(connectedPeerId);
            // Don't delete — other peers still need this broadcast.
            await DtnQueue.recordBroadcastSent(packet.msgId);
            Logger.debug(
                'ConnectionManager: broadcast ${packet.msgId} → $connectedPeerId');
          }
        } catch (e) {
          Logger.error(
              'ConnectionManager: error sending broadcast ${packet.msgId}', e);
        }
      }
      Logger.info(
          'ConnectionManager: broadcast flush — $bSynced/${broadcastPkts.length} '
          'sent to $connectedPeerId');
    }

    // ── Unicast packets destined specifically for this peer ────────
    final relevant = dtnPending.where((pkt) =>
        pkt.toUserId == connectedPeerId).toList();

    if (relevant.isEmpty) {
      Logger.info(
          'ConnectionManager: no pending DTN messages for $connectedPeerId');
    } else {
      Logger.info(
          'ConnectionManager: syncing ${relevant.length} DTN packet(s) '
          'to newly connected peer $connectedPeerId');

      int synced = 0;
      for (final packet in relevant) {
        try {
          final sent = await _wifiDirectService.sendMessage(packet.toWire());
          if (sent) {
            synced++;
            await DtnQueue.recordAttempt(packet.msgId, delivered: true);
            Logger.debug(
                'ConnectionManager: synced DTN packet '
                '${packet.msgId} → $connectedPeerId');
          }
        } catch (e) {
          Logger.error(
              'ConnectionManager: error syncing DTN packet ${packet.msgId}', e);
        }
      }
      Logger.info(
          'ConnectionManager: DTN sync complete — $synced/${relevant.length} '
          'packet(s) forwarded to $connectedPeerId');
    }

    // ── Legacy path: PendingMessageStorage (Hive) ─────────────────
    // Only sync messages destined for this specific peer.
    final hivePending = PendingMessageStorage.getAllPendingMessages();
    final hiveRelevant = hivePending.where((msg) =>
        msg.receiverId == connectedPeerId).toList();

    if (hiveRelevant.isEmpty) return;

    Logger.info(
        'ConnectionManager: syncing ${hiveRelevant.length} legacy pending '
        'message(s) to $connectedPeerId');

    int legacySynced = 0;
    for (final message in hiveRelevant) {
      try {
        final messageJson = jsonEncode(message.toJson());
        final sent = await _wifiDirectService.sendMessage(messageJson);
        if (sent) {
          legacySynced++;
          await PendingMessageStorage.removePendingMessage(message.messageId);
          Logger.debug(
              'ConnectionManager: synced legacy message '
              '${message.messageId} → $connectedPeerId');
        }
      } catch (e) {
        Logger.error(
            'ConnectionManager: error syncing message ${message.messageId}', e);
      }
    }

    Logger.info(
        'ConnectionManager: legacy sync complete — $legacySynced/${hiveRelevant.length} '
        'message(s) forwarded to $connectedPeerId');
  }

  // ═══════════════════════════════════════════════════════════════════
  // DTN auto-connect: silently connect when BLE sees a peer with pending msgs
  // ═══════════════════════════════════════════════════════════════════

  /// Called every time BLE discovers a batch of devices.
  /// If any device has pending DTN messages and we're not already connected,
  /// silently initiate a Wi-Fi Direct connection to flush the queue (T2).
  Future<void> _checkAndAutoConnectForPendingMessages(
      List<DeviceModel> discoveredDevices) async {
    // Don't interrupt an existing connection or connecting attempt.
    if (isConnected() || _currentConnectionType != ConnectionType.none) return;
    // Don't auto-connect if user explicitly cancelled / disconnected recently.
    if (_userInitiatedDisconnect) return;

    try {
      final pending = await DtnQueue.getPendingPackets();
      if (pending.isEmpty) return;

      // ── Broadcast packets: deliver to ALL visible peers ──────────
      // Broadcasts use toUserId == '*' which never matches a device UUID.
      // We queue EVERY visible BLE peer that hasn't yet received each
      // active broadcast, then connect to them one by one.
      final hasBroadcasts = pending.any((p) => p.toUserId == '*');
      if (hasBroadcasts) {
        final broadcasts = await DtnQueue.getPendingBroadcasts();
        if (broadcasts.isNotEmpty) {
          _broadcastDeliveryQueue.clear();
          for (final device in discoveredDevices) {
            final allDelivered = broadcasts.every((pkt) =>
                _broadcastDeliveredTo[pkt.msgId]?.contains(device.id) ??
                false);
            if (!allDelivered) {
              _broadcastDeliveryQueue.add(device);
            }
          }
          if (_broadcastDeliveryQueue.isNotEmpty) {
            final target = _broadcastDeliveryQueue.removeAt(0);
            _isAutoBroadcastConnection = true;
            Logger.info(
                '[BROADCAST] Starting delivery round — '
                '${_broadcastDeliveryQueue.length + 1} peer(s) queued; '
                'connecting to ${target.name} first');
            unawaited(connectToDevice(target));
            return;
          }
        }
      }

      // ── Unicast packets: connect only to the specific target peer ─
      // Build a set of peer UUIDs that have pending outbound messages.
      final pendingTargets = pending.map((p) => p.toUserId).toSet();

      // Check if any currently visible BLE device is a pending target.
      for (final device in discoveredDevices) {
        if (pendingTargets.contains(device.id)) {
          Logger.info(
              '[DTN] BLE rediscovered ${device.name} (${device.id}) '
              'with ${pending.where((p) => p.toUserId == device.id).length} '
              'pending message(s) — auto-connecting to deliver');
          // connectToDevice is safe to call: it guards against double-invocation.
          unawaited(connectToDevice(device));
          return; // only connect to one peer at a time
        }
      }
    } catch (e) {
      Logger.error('[DTN] Error in auto-connect check', e);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Broadcast sequential-delivery: auto-disconnect and connect to next
  // ═══════════════════════════════════════════════════════════════════

  /// Called after [_syncPendingMessages] finishes for a peer.
  ///
  /// If this connection was opened automatically by the broadcast-delivery
  /// system ([_isAutoBroadcastConnection] == true) AND there are more peers
  /// queued in [_broadcastDeliveryQueue], this method:
  ///   1. Gracefully disconnects from the current peer
  ///   2. Waits 600 ms for the P2P stack to settle
  ///   3. Connects to the next peer in the queue
  ///
  /// If there are no more peers (delivery round complete) or the current
  /// connection was user-initiated, this is a no-op.
  void _scheduleNextBroadcastDelivery(String deliveredToPeerId) {
    if (!_isAutoBroadcastConnection) return;

    if (_broadcastDeliveryQueue.isEmpty) {
      Logger.info(
          '[BROADCAST] Delivery round complete — '
          'all queued peers reached. Clearing auto-connect flag.');
      _isAutoBroadcastConnection = false;
      return;
    }

    final remaining = _broadcastDeliveryQueue.length;
    Logger.info(
        '[BROADCAST] Delivered to $deliveredToPeerId — '
        '$remaining peer(s) still queued. Auto-disconnecting…');

    // Nullify _lastConnectedDevice so the disconnect callback does NOT
    // trigger the normal auto-reconnect loop.  We manage reconnection
    // ourselves by connecting to the next queued peer.
    _lastConnectedDevice = null;

    _sendGracefulDisconnect().then((_) async {
      await _wifiDirectService.disconnect();

      if (_connectedPeerId != null) {
        _transportManager.removeNeighbor(_connectedPeerId!);
        _peerDiscovery.removePeer(_connectedPeerId!);
      }
      _currentConnectionType = ConnectionType.none;
      _connectedDevice = null;
      _connectedPeerId = null;

      // Short pause so the Wi-Fi Direct P2P stack fully releases the group.
      await Future.delayed(const Duration(milliseconds: 600));

      if (_broadcastDeliveryQueue.isEmpty) {
        _isAutoBroadcastConnection = false;
        return;
      }

      final next = _broadcastDeliveryQueue.removeAt(0);
      Logger.info('[BROADCAST] Connecting to next peer: ${next.name}');
      _isAutoBroadcastConnection = true; // still in delivery round
      unawaited(connectToDevice(next));
    }).catchError((Object e) {
      Logger.error(
          '[BROADCAST] Error during auto-disconnect for delivery round', e);
      _isAutoBroadcastConnection = false;
    });
  }

  // ═══════════════════════════════════════════════════════════════════
  // Feature 4: Presence Tracking
  // ═══════════════════════════════════════════════════════════════════

  /// Start the background BLE presence scanner for saved contacts.
  /// Safe to call multiple times — will no-op if already tracking.
  Future<void> _startPresenceTracking() async {
    try {
      await PresenceService.instance.startTracking();
    } catch (e) {
      Logger.error('ConnectionManager: error starting presence tracking', e);
    }
  }

  // ── Storage helper (inline, avoids extra import) ───────────────────
  final ScanLogStorage _scanLogStorage = ScanLogStorage.instance;
}
