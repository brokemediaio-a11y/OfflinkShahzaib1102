import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/app_colors.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../models/conversation_model.dart';
import '../../models/known_contact_model.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/device_provider.dart';
import '../../providers/known_contacts_provider.dart';
import '../../services/storage/device_storage.dart';
import '../../utils/logger.dart';
import '../chat/chat_screen.dart';

class MessagesScreen extends ConsumerStatefulWidget {
  const MessagesScreen({super.key});

  @override
  ConsumerState<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends ConsumerState<MessagesScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(conversationsProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final conversationsState = ref.watch(conversationsProvider);
    final connectionState = ref.watch(connectionProvider);
    final knownContacts = ref.watch(knownContactsProvider);
    final deviceState = ref.watch(deviceProvider);

    // IDs of contacts that are currently visible via BLE
    final discoveredIds =
        deviceState.discoveredDevices.map((d) => d.id).toSet();

    // IDs that already have a conversation thread
    final conversationIds =
        conversationsState.conversations.map((c) => c.deviceId).toSet();

    // Known contacts that DON'T have a conversation yet
    final contactsWithoutConversation = knownContacts
        .where((c) => !conversationIds.contains(c.peerId))
        .toList();

    final hasConversations = conversationsState.conversations.isNotEmpty;
    final hasNewContacts = contactsWithoutConversation.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
      ),
      body: conversationsState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : (!hasConversations && !hasNewContacts)
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 64,
                        color: AppColors.textSecondary.withOpacity(0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No messages yet',
                        style: TextStyle(
                          fontSize: 16,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Start a conversation by connecting to a device',
                        style: TextStyle(
                          fontSize: 14,
                          color: AppColors.textSecondary.withOpacity(0.7),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    ref.read(conversationsProvider.notifier).refresh();
                    ref.invalidate(knownContactsProvider);
                  },
                  child: ListView(
                    padding:
                        const EdgeInsets.all(AppConstants.defaultPadding),
                    children: [
                      // ── Active Conversations ──────────────────────
                      if (hasConversations) ...[
                        if (hasNewContacts)
                          Padding(
                            padding:
                                const EdgeInsets.only(bottom: 8, left: 4),
                            child: Text(
                              'Conversations',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ...conversationsState.conversations.map((conversation) {
                          final isConnected =
                              connectionState.connectedDevice?.id ==
                                  conversation.deviceId;
                          return _ConversationTile(
                            conversation: conversation,
                            isConnected: isConnected,
                            onTap: () =>
                                _openConversation(context, conversation),
                          );
                        }),
                      ],

                      // ── Known Contacts without conversations ──────
                      if (hasNewContacts) ...[
                        if (hasConversations)
                          const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8, left: 4),
                          child: Text(
                            'Known Contacts',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.textSecondary,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        ...contactsWithoutConversation
                            .map((contact) {
                          final isOnline =
                              discoveredIds.contains(contact.peerId) ||
                                  connectionState.connectedDevice?.id ==
                                      contact.peerId;
                          return _KnownContactTile(
                            contact: contact,
                            isOnline: isOnline,
                            onTap: () =>
                                _openContactChat(context, contact),
                          );
                        }),
                      ],
                    ],
                  ),
                ),
    );
  }

  // ── Navigation helpers ────────────────────────────────────────────

  /// Open an existing conversation thread.
  Future<void> _openConversation(
      BuildContext context, ConversationModel conversation) async {
    ref
        .read(conversationsProvider.notifier)
        .markAsRead(conversation.deviceId);

    final storedName =
        DeviceStorage.getDeviceDisplayName(conversation.deviceId);
    final displayName = storedName ??
        (conversation.deviceName != conversation.deviceId
            ? conversation.deviceName
            : conversation.deviceId);

    final device = DeviceModel(
      id: conversation.deviceId,
      name: displayName,
      address: conversation.deviceId,
      type: DeviceType.ble,
      rssi: 0,
      lastSeen: conversation.lastMessageTime,
    );

    if (!context.mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(device: device)),
    );
  }

  /// Open a chat with a known contact (no existing conversation).
  void _openContactChat(BuildContext context, KnownContact contact) {
    final device = DeviceModel(
      id: contact.peerId,
      name: contact.displayName,
      address: contact.deviceAddress ?? contact.peerId,
      type: DeviceType.ble,
      rssi: 0,
      lastSeen: contact.lastSeen,
    );
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(device: device)),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════
// Conversation Tile
// ══════════════════════════════════════════════════════════════════════

class _ConversationTile extends StatelessWidget {
  final ConversationModel conversation;
  final bool isConnected;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.conversation,
    required this.isConnected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Avatar with online dot
              Stack(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: isConnected
                          ? AppColors.primary.withOpacity(0.1)
                          : AppColors.textSecondary.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isConnected
                          ? Icons.bluetooth_connected
                          : Icons.bluetooth,
                      color: isConnected
                          ? AppColors.primary
                          : AppColors.textSecondary,
                    ),
                  ),
                  if (isConnected)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 16),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conversation.deviceName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      conversation.lastMessage,
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Time and unread badge
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatTime(conversation.lastMessageTime),
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (conversation.unreadCount > 0) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        conversation.unreadCount > 99
                            ? '99+'
                            : '${conversation.unreadCount}',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppColors.textLight,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);
    if (difference.inDays == 0) return DateFormat('HH:mm').format(timestamp);
    if (difference.inDays == 1) return 'Yesterday';
    if (difference.inDays < 7) return DateFormat('EEE').format(timestamp);
    return DateFormat('MM/dd').format(timestamp);
  }
}

// ══════════════════════════════════════════════════════════════════════
// Known Contact Tile  (no conversation yet)
// ══════════════════════════════════════════════════════════════════════

class _KnownContactTile extends StatelessWidget {
  final KnownContact contact;
  final bool isOnline;
  final VoidCallback onTap;

  const _KnownContactTile({
    required this.contact,
    required this.isOnline,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
        side: BorderSide(
          color: isOnline
              ? Colors.green.withOpacity(0.4)
              : AppColors.textSecondary.withOpacity(0.15),
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Avatar with online/offline dot
              Stack(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: isOnline
                          ? Colors.green.withOpacity(0.1)
                          : AppColors.textSecondary.withOpacity(0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.person_outline,
                      color: isOnline
                          ? Colors.green.shade600
                          : AppColors.textSecondary,
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color:
                            isOnline ? Colors.green : AppColors.textSecondary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              // Name + status
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      contact.displayName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isOnline ? 'In range — tap to chat' : 'No messages yet',
                      style: TextStyle(
                        fontSize: 13,
                        color: isOnline
                            ? Colors.green.shade600
                            : AppColors.textSecondary,
                        fontStyle: isOnline
                            ? FontStyle.normal
                            : FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Last seen
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    isOnline ? 'Online' : _formatLastSeen(contact.lastSeen),
                    style: TextStyle(
                      fontSize: 12,
                      color: isOnline ? Colors.green : AppColors.textSecondary,
                      fontWeight:
                          isOnline ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatLastSeen(DateTime lastSeen) {
    final now = DateTime.now();
    final diff = now.difference(lastSeen);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return DateFormat('MM/dd').format(lastSeen);
  }
}
