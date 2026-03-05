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

  // ── Dart-side streams ─────────────────────────────────────────────
  final _messageController =
      StreamController<String>.broadcast();
  final _connectionStateController =
      StreamController<WifiDirectConnectionState>.broadcast();
  final _peersController =
      StreamController<List<WifiDirectPeer>>.broadcast();
  final _invitationController =
      StreamController<Map<String, String>>.broadcast();

  StreamSubscription? _messageSubscription;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _peersSubscription;
  StreamSubscription? _invitationSubscription;

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

  // ═════════════════════════════════════════════════════════════════
  // Initialization
  // ═════════════════════════════════════════════════════════════════

  Future<bool> initialize() async {
    if (_initialized) return true;
    try {
      final result =
          await _methodChannel.invokeMethod<bool>('initialize');
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
          };
          Logger.info(
              'WifiDirectService: incoming invitation from ${payload["deviceName"]}');
          _invitationController.add(payload);
        }
      },
      onError: (e) =>
          Logger.error('WifiDirectService: invitation stream error', e),
    );
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

  /// Initiate a Wi-Fi Direct connection to the peer identified by [targetName].
  ///
  /// [targetName] is the peer's display name as broadcast via BLE.
  /// The native layer will discover nearby P2P peers and connect to
  /// the one whose deviceName matches [targetName].
  Future<Map<String, dynamic>> initiateConnection({
    required String targetName,
  }) async {
    if (!_initialized) {
      Logger.error('WifiDirectService: not initialized');
      return {'success': false, 'error': 'Not initialized'};
    }
    try {
      Logger.info(
          'WifiDirectService: initiating connection to peer "$targetName"');
      final result = await _methodChannel.invokeMethod<Map>(
        'initiateConnection',
        {'targetName': targetName},
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

  /// Connect to device — wraps [initiateConnection] using device name.
  Future<bool> connectToDevice(DeviceModel device) async {
    final result = await initiateConnection(targetName: device.name);
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
    _messageController.close();
    _connectionStateController.close();
    _peersController.close();
    _invitationController.close();
    disconnect();
  }
}
