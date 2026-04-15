import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/broadcast_message.dart';
import '../models/message_packet.dart';
import '../services/storage/broadcast_storage.dart';
import '../services/storage/device_storage.dart';
import '../services/group_session_manager.dart';
import '../utils/logger.dart';
import 'connection_provider.dart';

// ════════════════════════════════════════════════════════════════════════════
// State
// ════════════════════════════════════════════════════════════════════════════

class BroadcastState {
  /// All broadcasts (sent + received), newest first.
  final List<BroadcastMessage> broadcasts;
  final bool isSending;
  final bool isLoading;

  // ── Multi-GO group session UI state ─────────────────────────────────
  /// True when this device is the Group Owner of an active broadcast group.
  final bool isGroupOwner;
  /// True when this device is a member (GO or client) of an active group.
  final bool isInGroup;
  /// Group Owner peer ID (null if not in a group or if we are the GO).
  final String? groupOwnerId;
  /// UUIDs of all currently connected group members (GO-side only).
  final Set<String> groupMembers;

  const BroadcastState({
    this.broadcasts = const [],
    this.isSending = false,
    this.isLoading = false,
    this.isGroupOwner = false,
    this.isInGroup = false,
    this.groupOwnerId,
    this.groupMembers = const {},
  });

  BroadcastState copyWith({
    List<BroadcastMessage>? broadcasts,
    bool? isSending,
    bool? isLoading,
    bool? isGroupOwner,
    bool? isInGroup,
    String? groupOwnerId,
    Set<String>? groupMembers,
  }) =>
      BroadcastState(
        broadcasts: broadcasts ?? this.broadcasts,
        isSending: isSending ?? this.isSending,
        isLoading: isLoading ?? this.isLoading,
        isGroupOwner: isGroupOwner ?? this.isGroupOwner,
        isInGroup: isInGroup ?? this.isInGroup,
        groupOwnerId: groupOwnerId ?? this.groupOwnerId,
        groupMembers: groupMembers ?? this.groupMembers,
      );
}

// ════════════════════════════════════════════════════════════════════════════
// Notifier
// ════════════════════════════════════════════════════════════════════════════

class BroadcastNotifier extends StateNotifier<BroadcastState> {
  final Ref _ref;
  StreamSubscription<GroupMemberEvent>? _memberEventSub;

  BroadcastNotifier(this._ref) : super(const BroadcastState()) {
    _load();
    _subscribeToGroupEvents();
  }

  void _subscribeToGroupEvents() {
    _memberEventSub?.cancel();
    _memberEventSub =
        GroupSessionManager().memberEvents.listen((_) => _syncGroupState());
  }

  /// Pull the current group state from [GroupSessionManager] into this state.
  void _syncGroupState() {
    final session = GroupSessionManager();
    state = state.copyWith(
      isGroupOwner: session.isGroupOwner,
      isInGroup: session.isInGroup,
      groupOwnerId: session.groupOwnerId,
      groupMembers: Set<String>.from(session.members),
    );
  }

  @override
  void dispose() {
    _memberEventSub?.cancel();
    super.dispose();
  }

  // ─── Load ─────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    state = state.copyWith(isLoading: true);
    try {
      final msgs = await BroadcastStorage.getAll();
      state = state.copyWith(broadcasts: msgs, isLoading: false);
    } catch (e) {
      Logger.error('BroadcastProvider: error loading broadcasts', e);
      state = state.copyWith(isLoading: false);
    }
  }

  // ─── Receive ──────────────────────────────────────────────────────────────

  /// Called by [ConnectionProvider] when a `__broadcast__` event arrives
  /// from the mesh layer.  The [json] map has the structure emitted by
  /// [MeshHandler._deliverBroadcastToSelf].
  Future<void> addReceived(Map<String, dynamic> json) async {
    try {
      final msg = BroadcastMessage.fromMeshEvent(json);

      // Dedup — SeenCache handles the wire level; this guards the UI/DB level.
      if (state.broadcasts.any((b) => b.id == msg.id)) return;

      await BroadcastStorage.save(msg);
      state = state.copyWith(broadcasts: [msg, ...state.broadcasts]);
      Logger.info(
          'BroadcastProvider: received broadcast ${msg.id} '
          'from ${msg.senderName} (hop=${msg.hopCount})');
    } catch (e) {
      Logger.error('BroadcastProvider: error handling received broadcast', e);
    }
  }

  // ─── Send ─────────────────────────────────────────────────────────────────

  /// Compose and send a broadcast to all reachable (and future DTN) peers.
  ///
  /// [text] — the message to broadcast.
  /// [lat] / [lng] — optional GPS coordinates attached to the broadcast.
  ///
  /// The message is persisted immediately so it shows in the UI even if no
  /// peers are in range yet.  [DtnRetryLoop] will deliver it when peers appear.
  ///
  /// Returns true if the broadcast was sent over the air now, false if queued.
  Future<bool> sendBroadcast(
    String text, {
    double? lat,
    double? lng,
  }) async {
    if (text.trim().isEmpty) return false;

    state = state.copyWith(isSending: true);
    try {
      final myId = DeviceStorage.getDeviceId();
      // Prefer the user-chosen display name; fall back to UUID.
      final myName = DeviceStorage.getDisplayName() ?? myId;

      // Build the wire payload.
      final payloadMap = <String, dynamic>{
        'text': text.trim(),
        'senderName': myName,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
      };

      final packet = MessagePacket(
        msgId: const Uuid().v4(),
        toUserId: '*',        // wildcard → all peers
        fromUserId: myId,
        payload: jsonEncode(payloadMap),
        ttl: 5,               // 5 hops ≈ 250+ m logical range
        hopCount: 0,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        type: 'broadcast',
      );

      // ── Persist immediately ──────────────────────────────────────
      final selfMsg = BroadcastMessage(
        id: packet.msgId,
        fromUserId: myId,
        senderName: myName,
        text: text.trim(),
        latitude: lat,
        longitude: lng,
        timestamp: packet.timestamp,
        hopCount: 0,
        isSelf: true,
      );
      await BroadcastStorage.save(selfMsg);
      state = state.copyWith(broadcasts: [selfMsg, ...state.broadcasts]);

      // ── Route: Multi-GO group (simultaneous) or DTN epidemic (fallback) ───
      final session = GroupSessionManager();
      final sent = await _ref
          .read(connectionProvider.notifier)
          .routeBroadcastPacket(packet, senderUuid: myId);

      final mode = session.isGroupOwner
          ? 'Multi-GO (sent to ${session.memberCount} clients)'
          : session.isInGroup
              ? 'Multi-GO client → GO relay'
              : 'DTN epidemic';

      Logger.info(
          'BroadcastProvider: broadcast ${packet.msgId} '
          '${sent ? "sent [$mode]" : "queued in DTN"}');
      return sent;
    } catch (e) {
      Logger.error('BroadcastProvider: sendBroadcast error', e);
      return false;
    } finally {
      state = state.copyWith(isSending: false);
    }
  }

  // ─── Multi-GO Group Actions ────────────────────────────────────────────────

  /// Start this device as the Group Owner (user taps "Start Group").
  ///
  /// Delegates to [ConnectionManager.startBroadcastGroup()].
  /// On success, [GroupSessionManager] emits a member event that updates state.
  Future<bool> startBroadcastGroup() async {
    final ok =
        await _ref.read(connectionProvider.notifier).startBroadcastGroup();
    if (ok) _syncGroupState();
    return ok;
  }

  /// Leave the current broadcast group (both GO and client).
  ///
  /// For GO: disconnects all clients and tears down the P2P group.
  /// For client: disconnects from the GO.
  Future<void> leaveBroadcastGroup() async {
    await _ref.read(connectionProvider.notifier).disconnect();
    GroupSessionManager().leaveGroup();
    _syncGroupState();
  }

  // ─── Housekeeping ─────────────────────────────────────────────────────────

  /// Prune broadcasts older than 7 days from local storage.
  Future<void> pruneOld() async {
    try {
      await BroadcastStorage.deleteOlderThan(const Duration(days: 7));
      await _load();
    } catch (e) {
      Logger.error('BroadcastProvider: error pruning broadcasts', e);
    }
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Provider
// ════════════════════════════════════════════════════════════════════════════

final broadcastProvider =
    StateNotifierProvider<BroadcastNotifier, BroadcastState>((ref) {
  return BroadcastNotifier(ref);
});
