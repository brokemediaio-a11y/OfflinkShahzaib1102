import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_colors.dart';
import '../../models/device_model.dart';
import '../../models/known_contact_model.dart';
import '../../providers/connection_provider.dart';
import '../../services/communication/connection_manager.dart';
import '../../services/storage/known_contacts_storage.dart';
import '../chat/chat_screen.dart';

/// Contact Book Screen — shows all permanently saved contacts.
///
/// Status logic (in priority order):
///   🟢 Connected  — active WiFi Direct socket open to THIS device right now
///   🟡 In range   — device seen in the current BLE scan (advertised in last 15s)
///   ⚫ Last seen  — device not currently advertising, show time since last contact
///
/// The screen refreshes its contact list every time it becomes visible
/// (app resume, navigation back) via [WidgetsBindingObserver].
class ContactBookScreen extends ConsumerStatefulWidget {
  const ContactBookScreen({super.key});

  @override
  ConsumerState<ContactBookScreen> createState() => _ContactBookScreenState();
}

class _ContactBookScreenState extends ConsumerState<ContactBookScreen>
    with WidgetsBindingObserver {
  List<KnownContact> _contacts = [];

  /// UUIDs of devices seen in the most recent BLE scan (in-range detection).
  final Set<String> _bleVisibleUuids = {};

  StreamSubscription<List<DeviceModel>>? _bleSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadContacts();
    _subscribeToBleScan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bleSub?.cancel();
    super.dispose();
  }

  /// Called when the app comes back to the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadContacts();
    }
  }

  /// Called when navigating back to this screen via the Navigator.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload every time this route becomes the top-most route again.
    _loadContacts();
  }

  // ── Data loading ─────────────────────────────────────────────────

  void _loadContacts() {
    final fresh = KnownContactsStorage.getAllContacts()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    if (mounted) setState(() => _contacts = fresh);
  }

  /// Subscribe to live BLE scan results so we can show "In range" in real-time.
  void _subscribeToBleScan() {
    _bleSub?.cancel();
    _bleSub = ConnectionManager()
        .getDiscoveredDevices()
        .listen((devices) {
      if (!mounted) return;
      setState(() {
        _bleVisibleUuids
          ..clear()
          ..addAll(devices.map((d) => d.id));
      });
    });
  }

  // ── Build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final connectionState = ref.watch(connectionProvider);

    // Only trust "connected" if WiFi Direct socket is actually open.
    final activeConnectedId =
        connectionState.state == ConnectionStateType.connected
            ? connectionState.connectedDevice?.id
            : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contact Book'),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadContacts,
          ),
        ],
      ),
      body: _contacts.isEmpty
          ? _buildEmptyState()
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _contacts.length,
              itemBuilder: (context, index) {
                final contact = _contacts[index];
                final isConnected = contact.peerId == activeConnectedId;
                // "In range" = visible in current BLE scan AND not already connected
                final isInRange =
                    !isConnected && _bleVisibleUuids.contains(contact.peerId);
                return _buildContactTile(
                  contact,
                  isConnected: isConnected,
                  isInRange: isInRange,
                );
              },
            ),
    );
  }

  // ── Empty state ───────────────────────────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.contacts_outlined, size: 72, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'No saved contacts yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Contacts are saved automatically when you\nconnect to a nearby device.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  // ── Contact tile ──────────────────────────────────────────────────

  Widget _buildContactTile(
    KnownContact contact, {
    required bool isConnected,
    required bool isInRange,
  }) {
    Color badgeColor;
    String subtitle;
    Color subtitleColor;

    if (isConnected) {
      badgeColor = AppColors.connected;
      subtitle = 'Connected now';
      subtitleColor = AppColors.connected;
    } else if (isInRange) {
      badgeColor = AppColors.warning;
      subtitle = 'In range — tap to connect';
      subtitleColor = AppColors.warning;
    } else {
      badgeColor = AppColors.disconnected;
      subtitle = 'Last seen ${_formatTimeAgo(contact.lastSeen)}';
      subtitleColor = AppColors.textSecondary;
    }

    return Dismissible(
      key: Key(contact.peerId),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(contact),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        color: AppColors.error,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      child: ListTile(
        leading: Stack(
          children: [
            CircleAvatar(
              backgroundColor: AppColors.primaryLight,
              child: Text(
                contact.displayName.isNotEmpty
                    ? contact.displayName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: badgeColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ],
        ),
        title: Text(
          contact.displayName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: subtitleColor, fontSize: 13),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (contact.addedVia == 'firebase')
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(Icons.cloud, size: 16, color: Colors.grey[400]),
              ),
            Icon(Icons.chevron_right, color: Colors.grey[400]),
          ],
        ),
        // Chat is ALWAYS accessible — tap opens chat regardless of connection state.
        // DTN queuing means messages get delivered when the peer is in range.
        onTap: () => _openChat(contact),
        onLongPress: () => _showContactOptions(contact),
      ),
    );
  }

  // ── Navigation ────────────────────────────────────────────────────

  /// Opens the chat screen for this contact.
  /// Chat is always accessible — messages are queued via DTN if offline.
  void _openChat(KnownContact contact) {
    // Resolve the best known display name
    final device = DeviceModel(
      id: contact.peerId,
      name: contact.displayName,
      address: contact.deviceAddress ?? '',
      type: DeviceType.ble,
    );
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => ChatScreen(device: device)))
        .then((_) {
      // Refresh contacts list when returning from chat (lastSeen may have updated)
      _loadContacts();
    });
  }

  // ── Delete ────────────────────────────────────────────────────────

  Future<bool> _confirmDelete(KnownContact contact) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Contact'),
        content: Text(
          'Remove "${contact.displayName}" from your contact book?\n\n'
          'Chat history is preserved. You will need to '
          'rediscover this device to add them again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (result == true) {
      await KnownContactsStorage.deleteContact(contact.peerId);
      _loadContacts();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${contact.displayName} removed'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
    return false;
  }

  // ── Options sheet ─────────────────────────────────────────────────

  void _showContactOptions(KnownContact contact) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat),
              title: const Text('Open Chat'),
              onTap: () {
                Navigator.of(ctx).pop();
                _openChat(contact);
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Contact Info'),
              subtitle: Text(
                'UUID: ${contact.peerId}\n'
                'Added via: ${contact.addedVia}\n'
                'MAC: ${contact.deviceAddress ?? "unknown"}',
              ),
              isThreeLine: true,
              onTap: () => Navigator.of(ctx).pop(),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: AppColors.error),
              title: const Text('Delete Contact',
                  style: TextStyle(color: AppColors.error)),
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmDelete(contact);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────

  String _formatTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }
}
