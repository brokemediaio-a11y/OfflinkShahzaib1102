import 'dart:async';
import '../utils/logger.dart';

/// Membership event fired when a peer joins or leaves the Multi-GO group.
class GroupMemberEvent {
  final String type; // 'joined' | 'left'
  final String uuid;
  final int memberCount;
  const GroupMemberEvent({
    required this.type,
    required this.uuid,
    required this.memberCount,
  });
}

/// GroupSessionManager — tracks the Multi-GO broadcast group state.
///
/// Responsibilities:
///   - Record whether this device is the Group Owner (GO) or a client.
///   - Maintain the live set of member UUIDs (GO-side only).
///   - Expose a stream of [GroupMemberEvent]s for the UI member list.
///   - Persist the groupId so DTN layer can associate queued broadcasts.
///
/// Singleton.  ConnectionManager updates this after the native layer
/// confirms the GO role or a successful joinGroup handshake.
class GroupSessionManager {
  static final GroupSessionManager _instance = GroupSessionManager._internal();
  factory GroupSessionManager() => _instance;
  GroupSessionManager._internal();

  // ── State ─────────────────────────────────────────────────────────
  bool _isGroupOwner = false;
  String? _groupOwnerId;
  String? _groupId;
  final Set<String> _members = {};

  // ── Output stream ─────────────────────────────────────────────────
  final _memberEventController =
      StreamController<GroupMemberEvent>.broadcast();

  Stream<GroupMemberEvent> get memberEvents => _memberEventController.stream;

  // ── Getters ───────────────────────────────────────────────────────
  bool get isGroupOwner => _isGroupOwner;
  bool get isInGroup => _isGroupOwner || _groupOwnerId != null;
  String? get groupOwnerId => _groupOwnerId;
  String? get groupId => _groupId;
  Set<String> get members => Set.unmodifiable(_members);
  int get memberCount => _members.length;

  // ═══════════════════════════════════════════════════════════════════
  // State transitions
  // ═══════════════════════════════════════════════════════════════════

  /// Called when this device successfully starts the Multi-GO group.
  void becomeGroupOwner({required String myId, required String groupId}) {
    _isGroupOwner = true;
    _groupOwnerId = myId;
    _groupId = groupId;
    _members.clear();
    Logger.info('[GroupSession] Became Group Owner — groupId=$groupId');
  }

  /// Called when this device successfully joins a Multi-GO group as a client.
  void joinGroup({required String ownerId, required String groupId}) {
    _isGroupOwner = false;
    _groupOwnerId = ownerId;
    _groupId = groupId;
    _members.clear();
    Logger.info('[GroupSession] Joined group as client — GO=$ownerId groupId=$groupId');
  }

  /// Called when the group is dissolved (GO left, or explicit leave).
  void leaveGroup() {
    Logger.info('[GroupSession] Left group (was GO=$_isGroupOwner)');
    _isGroupOwner = false;
    _groupOwnerId = null;
    _groupId = null;
    _members.clear();
  }

  // ═══════════════════════════════════════════════════════════════════
  // Member management (GO-side, driven by native group_members channel)
  // ═══════════════════════════════════════════════════════════════════

  /// Process a raw group-member event map received from the native layer.
  ///
  /// Expected shape: { "event": "joined"|"left", "uuid": String, "memberCount": Int }
  void handleNativeMemberEvent(Map<dynamic, dynamic> map) {
    final event      = map['event']       as String? ?? '';
    final uuid       = map['uuid']        as String? ?? '';
    final count      = (map['memberCount'] as int?)  ?? 0;
    if (uuid.isEmpty) return;

    if (event == 'joined') {
      _members.add(uuid);
      Logger.info('[GroupSession] Member joined: $uuid ($count total)');
    } else if (event == 'left') {
      _members.remove(uuid);
      Logger.info('[GroupSession] Member left: $uuid ($count total)');
    }

    _memberEventController.add(GroupMemberEvent(
      type: event,
      uuid: uuid,
      memberCount: _members.length,
    ));
  }

  /// Update the member set from the connection-state payload
  /// (multiGoMembers list included in every GO state emission).
  void syncMembersFromState(List<String> memberUuids) {
    final added   = memberUuids.toSet().difference(_members);
    final removed = _members.difference(memberUuids.toSet());

    for (final uuid in added) {
      _members.add(uuid);
      _memberEventController.add(GroupMemberEvent(
        type: 'joined',
        uuid: uuid,
        memberCount: _members.length,
      ));
    }
    for (final uuid in removed) {
      _members.remove(uuid);
      _memberEventController.add(GroupMemberEvent(
        type: 'left',
        uuid: uuid,
        memberCount: _members.length,
      ));
    }
  }

  void dispose() => _memberEventController.close();
}
