import 'dart:async';
import 'package:flutter/services.dart';
import '../../models/device_model.dart';
import '../../utils/logger.dart';

/// Wi-Fi Direct connection state emitted by the native layer.
class WifiDirectConnectionState {
  final bool connected;
  final String? role;         // "group_owner" | "client"
  final String? ipAddress;    // Group Owner IP (192.168.49.1 for GO)
  final bool socketActive;    // True once TCP socket is established
  final String? status;       // "connecting" | null
  final String? error;

  WifiDirectConnectionState({
    required this.connected,
    this.role,
    this.ipAddress,
    this.socketActive = false,
    this.status,
    this.error,
  });

  factory WifiDirectConnectionState.fromMap(Map<dynamic, dynamic> map) {
    return WifiDirectConnectionState(
      connected: (map['connected'] as bool?) ?? false,
      role: map['role'] as String?,
      ipAddress: map['ipAddress'] as String?,
      socketActive: (map['socketActive'] as bool?) ?? false,
      status: map['status'] as String?,
      error: map['error'] as String?,
    );
  }

  bool get isGroupOwner => role == 'group_owner';
  bool get isClient => role == 'client';
  bool get isFullyConnected => connected && socketActive;
}

/// Wi-Fi Direct peer discovered by the native P2P layer.
class WifiDirectPeer {
  final String deviceName;
  final String deviceAddress;
  final int status;

  WifiDirectPeer({
    required this.deviceName,
    required this.deviceAddress,
    required this.status,
  });

  factory WifiDirectPeer.fromMap(Map<dynamic, dynamic> map) {
    return WifiDirectPeer(
      deviceName: map['deviceName'] as String? ?? 'Unknown',
      deviceAddress: map['deviceAddress'] as String? ?? '',
      status: map['status'] as int? ?? 3,
    );
  }
}

/// WifiDirectService — Data Plane (Messaging Transport)
///
/// This is the sole data transport for chat messages.
///
/// Responsibilities:
///   - Peer negotiation via Android WifiP2pManager
///   - Group Owner / Client role handling
///   - TCP socket establishment and lifecycle
///   - Byte-level send and receive
///   - Lifecycle callbacks to ConnectionManager
///
/// Integration path:
///   ConnectionManager → WifiDirectService → WifiDirectManager.kt (native)
class WifiDirectService {
  static final WifiDirectService _instance = WifiDirectService._internal();
  factory WifiDirectService() => _instance;
  WifiDirectService._internal();

  // ── Method & Event Channels ───────────────────────────────────────
  static const _methodChannel =
      MethodChannel('com.offlink.wifi_direct');
  static const _messageEventChannel =
      EventChannel('com.offlink.wifi_direct/messages');
  static const _connectionStateEventChannel =
      EventChannel('com.offlink.wifi_direct/connection_state');
  static const _peersEventChannel =
      EventChannel('com.offlink.wifi_direct/peers');
  static const _invitationEventChannel =
      EventChannel('com.offlink.wifi_direct/invitation');
  static const _discoveredServicesEventChannel =
      EventChannel('com.offlink.wifi_direct/discovered_services');
  static const _groupMembersEventChannel =
      EventChannel('com.offlink.wifi_direct/group_members');

  // ── Dart-side streams ─────────────────────────────────────────────
  final _messageController =
      StreamController<String>.broadcast();
  final _connectionStateController =
      StreamController<WifiDirectConnectionState>.broadcast();
  final _peersController =
      StreamController<List<WifiDirectPeer>>.broadcast();
  final _invitationController =
      StreamController<Map<String, String>>.broadcast();
  final _discoveredServicesController =
      StreamController<List<Map<String, dynamic>>>.broadcast();
  final _groupMembersController =
      StreamController<Map<String, dynamic>>.broadcast();

  StreamSubscription? _messageSubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _peersSubscription;
  StreamSubscription? _invitationSubscription;
  StreamSubscription? _discoveredServicesSubscription;
  StreamSubscription? _groupMembersSubscription;

  bool _initialized = false;

  // Last known connection state (for synchronous queries)
  WifiDirectConnectionState _lastState = WifiDirectConnectionState(
    connected: false,
  );

  /// Stream of JSON-encoded chat messages received from the peer.
  Stream<String> get incomingMessages => _messageController.stream;

  /// Stream of Wi-Fi Direct connection state changes.
  Stream<WifiDirectConnectionState> get connectionState =>
      _connectionStateController.stream;

  /// Stream of discovered Wi-Fi Direct peers (P2P layer discovery).
  Stream<List<WifiDirectPeer>> get discoveredPeers => _peersController.stream;

  /// Fires on the RECEIVING device when a remote peer sends a connection
  /// invitation.  Map keys: "deviceName" and "deviceAddress".
  /// Flutter must respond by calling [acceptInvitation] or [rejectInvitation].
  Stream<Map<String, String>> get incomingInvitations =>
      _invitationController.stream;

  /// Stream of OffLink peers discovered via background Wi-Fi Direct DNS-SD
  /// service browsing (~200 m range), independent of BLE discovery (~50 m).
  /// Each list entry: { "uuid": String, "name": String?, "address": String }
  Stream<List<Map<String, dynamic>>> get discoveredServices =>
      _discoveredServicesController.stream;

  /// Stream of Multi-GO group member join/leave events.
  /// Each event: { "event": "joined"|"left", "uuid": String, "memberCount": int }
  Stream<Map<String, dynamic>> get groupMemberEvents =>
      _groupMembersController.stream;

  // ═════════════════════════════════════════════════════════════════
  // Initialization
  // ═════════════════════════════════════════════════════════════════

  /// [deviceUuid] — this device's OffLink UUID.  Passed to the native layer
  /// so it can register a DNS-SD Bonjour service immediately on init, making
  /// this device discoverable by UUID before any explicit connect() call.
  Future<bool> initialize({required String deviceUuid}) async {
    if (_initialized) return true;
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'initialize',
        {'deviceUuid': deviceUuid},
      );
      _initialized = result ?? false;

      if (_initialized) {
        _setupEventListeners();
        Logger.info('WifiDirectService: initialized');
      } else {
        Logger.warning('WifiDirectService: native initialization returned false');
      }
      return _initialized;
    } catch (e) {
      Logger.error('WifiDirectService: initialize error', e);
      return false;
    }
  }

  void _setupEventListeners() {
    // ── Incoming messages ──────────────────────────────────────────
    _messageSubscription?.cancel();
    _messageSubscription =
        _messageEventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is String) {
          Logger.debug(
              'WifiDirectService: received message (${event.length} chars)');
          _messageController.add(event);
        }
      },
      onError: (e) => Logger.error('WifiDirectService: message stream error', e),
    );

    // ── Connection state ──────────────────────────────────────────
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription =
        _connectionStateEventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final state = WifiDirectConnectionState.fromMap(event);
          _lastState = state;

          // Structured, high-signal log for debugging the native state machine.
          // This mirrors the style of the updateConversation logs so we can
          // correlate socket/phase with chat behaviour on each device.
          final phase = event['connectionPhase'] as String? ?? 'UNKNOWN';
          Logger.info(
            '🔌 WIFI_DIRECT_STATE: '
            'connected=${state.connected}, '
            'socketActive=${state.socketActive}, '
            'role=${state.role}, '
            'status=${state.status}, '
            'ip=${state.ipAddress}, '
            'error=${state.error}, '
            'phase=$phase',
          );

          _connectionStateController.add(state);
        }
      },
      onError: (e) =>
          Logger.error('WifiDirectService: connection state stream error', e),
    );

    // ── Wi-Fi P2P peers ───────────────────────────────────────────
    _peersSubscription?.cancel();
    _peersSubscription =
        _peersEventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is List) {
          final peers = event
              .whereType<Map>()
              .map((m) => WifiDirectPeer.fromMap(m))
              .toList();
          Logger.info(
              'WifiDirectService: ${peers.length} Wi-Fi P2P peer(s) discovered');
          _peersController.add(peers);
        }
      },
      onError: (e) => Logger.error('WifiDirectService: peers stream error', e),
    );

    // ── Incoming invitations ──────────────────────────────────────
    _invitationSubscription?.cancel();
    _invitationSubscription =
        _invitationEventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final payload = {
            'deviceName':    (event['deviceName']    as String?) ?? 'Unknown',
            'deviceAddress': (event['deviceAddress'] as String?) ?? '',
            'peerUuid':      (event['peerUuid']      as String?) ?? '',
          };
          Logger.info(
              'WifiDirectService: incoming invitation from ${payload["deviceName"]} '
              '(uuid=${payload["peerUuid"]!.isEmpty ? "unknown" : payload["peerUuid"]})');
          _invitationController.add(payload);
        }
      },
      onError: (e) =>
          Logger.error('WifiDirectService: invitation stream error', e),
    );

    // ── Background DNS-SD discovered services ─────────────────────
    _discoveredServicesSubscription?.cancel();
    _discoveredServicesSubscription =
        _discoveredServicesEventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is List) {
          final services = event
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          Logger.info(
              'WifiDirectService: ${services.length} peer(s) found via Wi-Fi Direct DNS-SD');
          _discoveredServicesController.add(services);
        }
      },
      onError: (e) =>
          Logger.error('WifiDirectService: discovered services stream error', e),
    );

    // ── Multi-GO group member join/leave events ────────────────────
    _groupMembersSubscription?.cancel();
    _groupMembersSubscription =
        _groupMembersEventChannel.receiveBroadcastStream().listen(
      (event) {
        if (event is Map) {
          final map = Map<String, dynamic>.from(event);
          Logger.info(
              'WifiDirectService: group member event '
              '${map["event"]} uuid=${map["uuid"]}');
          _groupMembersController.add(map);
        }
      },
      onError: (e) =>
          Logger.error('WifiDirectService: group members stream error', e),
    );
  }

  /// Embed our display name in the Wi-Fi Direct DNS-SD TXT record so remote
  /// devices can show our username even without a prior BLE discovery.
  Future<void> setOwnUsername(String name) async {
    try {
      await _methodChannel.invokeMethod('setOwnUsername', {'name': name});
    } catch (e) {
      Logger.error('WifiDirectService: setOwnUsername error', e);
    }
  }

  // ═════════════════════════════════════════════════════════════════
  // Discovery (P2P layer — separate from BLE)
  // ═════════════════════════════════════════════════════════════════

  /// Start Wi-Fi Direct peer discovery (P2P layer).
  /// This is called automatically by [initiateConnection].
  Future<Map<String, dynamic>> discoverPeers() async {
    try {
      final result =
          await _methodChannel.invokeMethod<Map>('discoverPeers');
      return result != null
          ? Map<String, dynamic>.from(result)
          : {'success': false, 'error': 'no result'};
    } catch (e) {
      Logger.error('WifiDirectService: discoverPeers error', e);
      return {'success': false, 'error': e.toString()};
    }
  }

  // ═════════════════════════════════════════════════════════════════
  // Connection
  // ═════════════════════════════════════════════════════════════════

  /// Initiate a Wi-Fi Direct connection to the peer identified by [targetUuid].
  ///
  /// [targetUuid] is the peer's OffLink UUID — the single authoritative identity.
  /// The native layer uses Wi-Fi Direct DNS-SD service discovery to resolve the
  /// UUID to a MAC address internally; the MAC never surfaces to Dart.
  ///
  /// [targetName] is the peer's display name (OffLink username), used only for
  /// logging and as a name-based fallback if DNS-SD doesn't respond within 15 s.
  Future<Map<String, dynamic>> initiateConnection({
    required String targetUuid,
    required String targetName,
  }) async {
    if (!_initialized) {
      Logger.error('WifiDirectService: not initialized');
      return {'success': false, 'error': 'Not initialized'};
    }
    try {
      Logger.info(
          'WifiDirectService: initiating UUID-based connection to '
          '"$targetName" (UUID=$targetUuid)');
      final result = await _methodChannel.invokeMethod<Map>(
        'initiateConnection',
        {'targetUuid': targetUuid, 'targetName': targetName},
      );
      final map = result != null
          ? Map<String, dynamic>.from(result)
          : {'success': false, 'error': 'no result'};
      Logger.info('WifiDirectService: initiateConnection result = $map');
      return map;
    } catch (e) {
      Logger.error('WifiDirectService: initiateConnection error', e);
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Accept a pending incoming Wi-Fi Direct invitation.
  /// Call this after the user taps "Accept" in the consent dialog.
  Future<Map<String, dynamic>> acceptInvitation() async {
    try {
      final result =
          await _methodChannel.invokeMethod<Map>('acceptInvitation');
      final map = result != null
          ? Map<String, dynamic>.from(result)
          : {'success': false, 'error': 'no result'};
      Logger.info('WifiDirectService: acceptInvitation result = $map');
      return map;
    } catch (e) {
      Logger.error('WifiDirectService: acceptInvitation error', e);
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Reject a pending incoming Wi-Fi Direct invitation.
  /// Call this after the user taps "Decline" in the consent dialog.
  Future<void> rejectInvitation() async {
    try {
      await _methodChannel.invokeMethod('rejectInvitation');
      Logger.info('WifiDirectService: rejectInvitation sent');
    } catch (e) {
      Logger.error('WifiDirectService: rejectInvitation error', e);
    }
  }

  /// Disconnect and remove the P2P group.
  Future<void> disconnect() async {
    try {
      await _methodChannel.invokeMethod('disconnect');
      Logger.info('WifiDirectService: disconnected');
    } catch (e) {
      Logger.error('WifiDirectService: disconnect error', e);
    }
  }

  // ═════════════════════════════════════════════════════════════════
  // Multi-GO Group Session
  // ═════════════════════════════════════════════════════════════════

  /// Start this device as a Wi-Fi Direct Group Owner (software AP).
  ///
  /// Uses [WifiP2pManager.createGroup()] with GO intent = 15, so no
  /// peer negotiation occurs — this device always wins the GO role.
  /// The native layer opens a multi-client TCP ServerSocket after the
  /// Android framework confirms the group is created.
  ///
  /// Returns `{ "success": bool }`.
  Future<Map<String, dynamic>> startAsGroupOwner() async {
    if (!_initialized) {
      return {'success': false, 'error': 'Not initialized'};
    }
    try {
      final result =
          await _methodChannel.invokeMethod<Map>('startAsGroupOwner');
      final map = result != null
          ? Map<String, dynamic>.from(result)
          : {'success': false, 'error': 'no result'};
      Logger.info('WifiDirectService: startAsGroupOwner → $map');
      return map;
    } catch (e) {
      Logger.error('WifiDirectService: startAsGroupOwner error', e);
      return {'success': false, 'error': e.toString()};
    }
  }

  // ═════════════════════════════════════════════════════════════════
  // Passive GO mode — dialog-free relay connections
  // ═════════════════════════════════════════════════════════════════

  /// Put this device into "Passive Group Owner" mode using credentials
  /// derived from [ownUuid].
  ///
  /// Any peer that knows our UUID can connect without a consent dialog by
  /// calling [connectToGroupByUuid] with our UUID.
  ///
  /// Call once during app startup (after [initialize]) and again after every
  /// relay disconnect via [restorePassiveGoMode].
  Future<Map<String, dynamic>> startPassiveGoMode(String ownUuid) async {
    if (!_initialized) return {'success': false, 'error': 'Not initialized'};
    try {
      final result = await _methodChannel.invokeMethod<Map>(
        'startPassiveGoMode',
        {'uuid': ownUuid},
      );
      final map = result != null
          ? Map<String, dynamic>.from(result)
          : {'success': false, 'error': 'no result'};
      Logger.info('WifiDirectService: startPassiveGoMode → $map');
      return map;
    } catch (e) {
      Logger.error('WifiDirectService: startPassiveGoMode error', e);
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Restore passive GO mode after a relay connection completes.
  ///
  /// This recreates the passive group so the device is ready to accept the
  /// next relay connection without a dialog.
  Future<Map<String, dynamic>> restorePassiveGoMode() async {
    if (!_initialized) return {'success': false, 'error': 'Not initialized'};
    try {
      final result =
          await _methodChannel.invokeMethod<Map>('restorePassiveGoMode');
      final map = result != null
          ? Map<String, dynamic>.from(result)
          : {'success': false, 'error': 'no result'};
      Logger.info('WifiDirectService: restorePassiveGoMode → $map');
      return map;
    } catch (e) {
      Logger.error('WifiDirectService: restorePassiveGoMode error', e);
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Connect to a relay peer's passive GO group using derived credentials.
  ///
  /// On Android 10+ this is completely dialog-free — credentials are derived
  /// from [targetUuid] and supplied directly via [WifiP2pConfig.Builder].
  ///
  /// On Android 9 the API is unavailable; the native layer falls back to the
  /// standard DNS-SD → WPS-PBC path (dialog may appear on relay device).
  ///
  /// Use this instead of [initiateConnection] for all relay/DTN hops.
  Future<Map<String, dynamic>> connectToGroupByUuid({
    required String targetUuid,
    required String targetName,
  }) async {
    if (!_initialized) return {'success': false, 'error': 'Not initialized'};
    try {
      Logger.info(
          'WifiDirectService: connectToGroupByUuid "$targetName" (UUID=$targetUuid)');
      final result = await _methodChannel.invokeMethod<Map>(
        'connectToGroupByUuid',
        {'targetUuid': targetUuid, 'targetName': targetName},
      );
      final map = result != null
          ? Map<String, dynamic>.from(result)
          : {'success': false, 'error': 'no result'};
      Logger.info('WifiDirectService: connectToGroupByUuid → $map');
      return map;
    } catch (e) {
      Logger.error('WifiDirectService: connectToGroupByUuid error', e);
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Join an existing Multi-GO group as a client.
  ///
  /// Delegates to the standard UUID-based connect path but yields the GO
  /// role (the remote device that called [startAsGroupOwner] wins).
  ///
  /// [targetUuid] — the Group Owner's OffLink UUID.
  /// [targetName] — fallback display name for DNS-SD.
  ///
  /// Returns `{ "success": bool }`.
  Future<Map<String, dynamic>> joinGroupAsClient({
    required String targetUuid,
    required String targetName,
  }) async {
    if (!_initialized) {
      return {'success': false, 'error': 'Not initialized'};
    }
    try {
      final result = await _methodChannel.invokeMethod<Map>(
        'joinGroupAsClient',
        {'targetUuid': targetUuid, 'targetName': targetName},
      );
      final map = result != null
          ? Map<String, dynamic>.from(result)
          : {'success': false, 'error': 'no result'};
      Logger.info('WifiDirectService: joinGroupAsClient → $map');
      return map;
    } catch (e) {
      Logger.error('WifiDirectService: joinGroupAsClient error', e);
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Send [message] to ALL connected Multi-GO clients simultaneously.
  ///
  /// [senderUuid] — UUID of the originating device; that socket is skipped
  ///   to prevent echo-back.  Pass null when the GO itself is the sender.
  ///
  /// Returns the count of client sockets that received the message.
  /// Returns -1 if the native call fails.
  Future<int> broadcastToAllClients(String message,
      {String? senderUuid}) async {
    if (!_initialized) return -1;
    try {
      final result = await _methodChannel.invokeMethod<int>(
        'broadcastToAllClients',
        {
          'message': message,
          if (senderUuid != null) 'senderUuid': senderUuid,
        },
      );
      return result ?? 0;
    } catch (e) {
      Logger.error('WifiDirectService: broadcastToAllClients error', e);
      return -1;
    }
  }

  /// Returns true if this device is currently acting as a Multi-GO owner.
  Future<bool> isMultiGoOwner() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isMultiGoOwner') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Returns the current count of connected Multi-GO clients (0 if not GO).
  Future<int> getGroupMemberCount() async {
    try {
      return await _methodChannel.invokeMethod<int>('getGroupMemberCount') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Returns the UUIDs of currently connected Multi-GO clients.
  Future<List<String>> getGroupMemberUuids() async {
    try {
      final result =
          await _methodChannel.invokeMethod<List>('getGroupMemberUuids');
      return result?.cast<String>() ?? [];
    } catch (_) {
      return [];
    }
  }

  // ═════════════════════════════════════════════════════════════════
  // Data Transport
  // ═════════════════════════════════════════════════════════════════

  /// Send a chat message string over the active Wi-Fi Direct socket.
  ///
  /// Returns true if the message was handed to the native send queue.
  /// Does NOT wait for TCP acknowledgement.
  Future<bool> sendMessage(String message) async {
    if (!_initialized) {
      Logger.error('WifiDirectService: not initialized — cannot send');
      return false;
    }
    try {
      final result = await _methodChannel.invokeMethod<bool>(
        'sendMessage',
        {'message': message},
      );
      final ok = result ?? false;
      if (ok) {
        Logger.debug(
            'WifiDirectService: message queued for socket delivery (${message.length} chars)');
      } else {
        Logger.error('WifiDirectService: native sendMessage returned false');
      }
      return ok;
    } catch (e) {
      Logger.error('WifiDirectService: sendMessage error', e);
      return false;
    }
  }

  // ═════════════════════════════════════════════════════════════════
  // Status queries
  // ═════════════════════════════════════════════════════════════════

  Future<bool> isConnected() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isConnected') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isSocketActive() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isSocketActive') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Returns the last known connection state without an async call.
  WifiDirectConnectionState get lastKnownState => _lastState;

  /// True once both P2P group is formed AND TCP socket is established.
  bool get isFullyConnected => _lastState.isFullyConnected;

  // ═════════════════════════════════════════════════════════════════
  // Legacy compatibility (kept for DeviceModel-based callers)
  // ═════════════════════════════════════════════════════════════════

  /// Connect to device — wraps [initiateConnection] using device UUID.
  Future<bool> connectToDevice(DeviceModel device) async {
    final result = await initiateConnection(
        targetUuid: device.id, targetName: device.name);
    return result['success'] == true;
  }

  /// Get a DeviceModel for the currently connected peer.
  ///
  /// Returns null if the socket is not fully established.
  ///
  /// NOTE: This method intentionally does NOT fabricate a device identity.
  /// The peer UUID is established via the UUID handshake in ConnectionManager
  /// and is stored in ConnectionManager._connectedPeerId.
  /// Callers that need a DeviceModel should use ConnectionManager.connectedDevice.
  Future<DeviceModel?> getConnectedDevice() async {
    if (!isFullyConnected) return null;
    // Peer UUID is unknown at this layer — it is resolved by ConnectionManager
    // via the UUID handshake.  Return null to force callers to use
    // ConnectionManager.connectedDevice which holds the resolved identity.
    return null;
  }

  // ═════════════════════════════════════════════════════════════════
  // Lifecycle
  // ═════════════════════════════════════════════════════════════════

  void dispose() {
    _messageSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _peersSubscription?.cancel();
    _invitationSubscription?.cancel();
    _discoveredServicesSubscription?.cancel();
    _groupMembersSubscription?.cancel();
    _messageController.close();
    _connectionStateController.close();
    _peersController.close();
    _invitationController.close();
    _discoveredServicesController.close();
    _groupMembersController.close();
    disconnect();
  }
}
