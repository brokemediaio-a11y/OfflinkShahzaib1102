import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_colors.dart';
import '../../core/app_strings.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../providers/device_provider.dart';
import '../../providers/connection_provider.dart';
import '../../services/communication/connection_manager.dart';
import '../../services/storage/known_contacts_storage.dart';
import '../../utils/logger.dart';
import '../chat/chat_screen.dart';
import '../connection/connection_status_screen.dart';
import '../contacts/contact_book_screen.dart';
import '../messages/messages_screen.dart';
import '../settings/edit_name_dialog.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // Tracks which device the user last tapped — used by ref.listen to navigate.
  DeviceModel? _pendingConnectionDevice;

  // Whether the connecting dialog is currently on screen.
  bool _connectingDialogOpen = false;

  // Prevents showing duplicate consent dialogs for the same invitation.
  bool _invitationDialogOpen = false;

  StreamSubscription<Map<String, String>>? _invitationSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _invitationSubscription?.cancel();
      _invitationSubscription = ref
          .read(connectionProvider.notifier)
          .incomingInvitations
          .listen(_onIncomingInvitation);
    });
  }

  @override
  void dispose() {
    _invitationSubscription?.cancel();
    super.dispose();
  }

  // ─── Connecting dialog ────────────────────────────────────────────────────

  /// Show a non-dismissible modal dialog with a spinner and a "Stop" button.
  void _showConnectingDialog(String deviceName) {
    if (_connectingDialogOpen) return;
    _connectingDialogOpen = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ConnectingDialog(
        deviceName: deviceName,
        onStop: () async {
          Navigator.of(ctx).pop();
          await ref.read(connectionProvider.notifier).cancelConnection();
        },
      ),
    ).then((_) {
      // Ensure the flag is cleared even if the dialog is popped externally.
      if (mounted) _connectingDialogOpen = false;
    });
  }

  /// Dismiss the connecting dialog if it is currently shown.
  void _dismissConnectingDialog() {
    if (!_connectingDialogOpen) return;
    _connectingDialogOpen = false;
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // ─── Incoming invitation ──────────────────────────────────────────────────

  Future<void> _onIncomingInvitation(Map<String, String> payload) async {
    if (!mounted || _invitationDialogOpen) return;

    final notifier = ref.read(connectionProvider.notifier);

    // Auto-accept: ongoing session reconnect
    if (notifier.isReconnecting) {
      Logger.info(
          'HomeScreen: auto-accepting reconnect invitation from '
          '${payload["deviceName"]}');
      await notifier.acceptInvitation();
      return;
    }

    // Auto-accept: caller is a known contact — deliver messages seamlessly
    // without any dialog. The UUID is provided by the Kotlin layer via DNS-SD.
    final peerUuid = payload['peerUuid'] ?? '';
    if (peerUuid.isNotEmpty && KnownContactsStorage.hasContact(peerUuid)) {
      Logger.info(
          'HomeScreen: auto-accepting invitation from known contact '
          '${payload["deviceName"]} (uuid=$peerUuid)');
      await notifier.acceptInvitation();
      return;
    }

    final callerName = payload['deviceName'] ?? 'Unknown Device';
    _invitationDialogOpen = true;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.wifi_tethering, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Connection Request',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RichText(
              text: TextSpan(
                style: const TextStyle(
                    fontSize: 15, color: AppColors.textPrimary),
                children: [
                  TextSpan(
                    text: callerName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const TextSpan(
                    text: ' wants to connect with you via Wi-Fi Direct.',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Accept to open a chat session.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Decline',
              style: TextStyle(color: AppColors.error),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: AppColors.textLight,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    _invitationDialogOpen = false;
    if (!mounted) return;

    if (accepted == true) {
      await notifier.acceptInvitation();
      // Chat screen opens via ref.listen when SOCKET_CONNECTED fires.
    } else {
      await notifier.rejectInvitation();
    }
  }

  // ─── Connect to device ────────────────────────────────────────────────────

  Future<void> _connectToDevice(DeviceModel device) async {
    _pendingConnectionDevice = device;

    final connectionNotifier = ref.read(connectionProvider.notifier);
    final started = await connectionNotifier.connectToDevice(device);

    if (!mounted) return;

    if (started) {
      // Show the modal connecting dialog with Stop button.
      _showConnectingDialog(device.name);
    } else {
      // Native layer rejected immediately — no need for a dialog.
      _pendingConnectionDevice = null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not start connection to ${device.name}. '
            'Ensure Wi-Fi Direct is enabled on both devices.',
          ),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final deviceState = ref.watch(deviceProvider);
    final connectionState = ref.watch(connectionProvider);

    // React to Wi-Fi Direct state transitions.
    ref.listen<ConnectionProviderState>(connectionProvider, (previous, next) {
      if (!mounted) return;

      if (previous?.state != ConnectionStateType.connected &&
          next.state == ConnectionStateType.connected) {
        // ── Socket confirmed open ────────────────────────────────────
        _dismissConnectingDialog();

        final chatDevice = _pendingConnectionDevice ?? next.connectedDevice;
        _pendingConnectionDevice = null;

        if (chatDevice != null) {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ChatScreen(device: chatDevice)),
          );
        }
      } else if (next.state == ConnectionStateType.error ||
          (next.state == ConnectionStateType.disconnected &&
              previous?.state == ConnectionStateType.connecting)) {
        // ── Connection attempt failed or timed out ───────────────────
        _dismissConnectingDialog();

        if (_pendingConnectionDevice != null) {
          final name = _pendingConnectionDevice!.name;
          _pendingConnectionDevice = null;

          // Use the human-readable error from the manager if available.
          final errorMsg =
              ref.read(connectionProvider.notifier).lastConnectionError ??
              'Connection to $name failed. '
                  'Ensure both devices have Wi-Fi Direct enabled.';

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMsg),
              backgroundColor: AppColors.error,
              duration: const Duration(seconds: 6),
            ),
          );
        } else {
          _pendingConnectionDevice = null;
        }
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.homeTitle),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Edit Device Name',
            onPressed: () async {
              final result = await showDialog<bool>(
                context: context,
                builder: (_) => const EditNameDialog(),
              );
              if (result == true && mounted) {
                final connectionManager = ConnectionManager();
                await connectionManager.restartAdvertising();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.contacts),
            tooltip: 'Contact Book',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ContactBookScreen()),
              );
            },
          ),
          IconButton(
            icon: Stack(
              children: const [Icon(Icons.message)],
            ),
            tooltip: 'Messages',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MessagesScreen()),
              );
            },
          ),
          if (connectionState.state == ConnectionStateType.connected &&
              connectionState.connectedDevice != null)
            IconButton(
              icon: const Icon(Icons.wifi_tethering),
              tooltip: 'Open Chat (Wi-Fi Direct)',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ChatScreen(device: connectionState.connectedDevice!),
                  ),
                );
              },
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'chat':
                  if (connectionState.connectedDevice != null) {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            ChatScreen(device: connectionState.connectedDevice!),
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('No device connected'),
                        backgroundColor: AppColors.error,
                      ),
                    );
                  }
                  break;
                case 'connection':
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const ConnectionStatusScreen()),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              if (connectionState.state == ConnectionStateType.connected)
                const PopupMenuItem(
                  value: 'chat',
                  child: Row(
                    children: [
                      Icon(Icons.chat, size: 20),
                      SizedBox(width: 8),
                      Text('Open Chat'),
                    ],
                  ),
                ),
              const PopupMenuItem(
                value: 'connection',
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 20),
                    SizedBox(width: 8),
                    Text('Connection Status'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Scan button ────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            color: AppColors.surface,
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: deviceState.isScanning
                        ? () => ref.read(deviceProvider.notifier).stopScan()
                        : () => ref.read(deviceProvider.notifier).startScan(),
                    icon: Icon(
                        deviceState.isScanning ? Icons.stop : Icons.search),
                    label: Text(deviceState.isScanning
                        ? AppStrings.stopScan
                        : AppStrings.scanDevices),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.textLight,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                            AppConstants.defaultBorderRadius),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── BLE scanning indicator ─────────────────────────────────
          if (deviceState.isScanning)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: AppColors.info.withOpacity(0.1),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Scanning for nearby peers via BLE…',
                    style: TextStyle(color: AppColors.info),
                  ),
                ],
              ),
            ),

          // ── Wi-Fi Direct status banner ─────────────────────────────
          if (connectionState.state == ConnectionStateType.connected &&
              connectionState.connectedDevice != null)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.green.withOpacity(0.12),
              child: Row(
                children: [
                  const Icon(Icons.wifi_tethering,
                      color: Colors.green, size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Connected to ${connectionState.connectedDevice!.name}',
                      style: const TextStyle(
                        color: Colors.green,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(connectionProvider.notifier).disconnect(),
                    child: const Text(
                      'Disconnect',
                      style: TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),

          // ── Error banner ───────────────────────────────────────────
          if (deviceState.error != null)
            Container(
              padding: const EdgeInsets.all(12),
              color: AppColors.error.withOpacity(0.1),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: AppColors.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      deviceState.error!,
                      style: const TextStyle(color: AppColors.error),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () =>
                        ref.read(deviceProvider.notifier).clearError(),
                  ),
                ],
              ),
            ),

          // ── Device list ────────────────────────────────────────────
          Expanded(
            child: deviceState.discoveredDevices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.devices_other,
                          size: 64,
                          color: AppColors.textSecondary.withOpacity(0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppStrings.noDevicesFound,
                          style: TextStyle(
                            fontSize: 16,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AppStrings.tapToConnect,
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary.withOpacity(0.7),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding:
                        const EdgeInsets.all(AppConstants.defaultPadding),
                    itemCount: deviceState.discoveredDevices.length,
                    itemBuilder: (context, index) {
                      final device =
                          deviceState.discoveredDevices[index];
                      return _DeviceCard(
                        device: device,
                        onTap: () => _connectToDevice(device),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── Connecting dialog widget ──────────────────────────────────────────────

class _ConnectingDialog extends StatelessWidget {
  final String deviceName;
  final VoidCallback onStop;

  const _ConnectingDialog({
    required this.deviceName,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Animated spinner
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppColors.primary),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Title
          const Text(
            'Connecting…',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          // Device name
          Text(
            deviceName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Establishing Wi-Fi Direct link.\nThis may take up to 30 seconds.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          // Stop button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_circle_outlined,
                  color: AppColors.error),
              label: const Text(
                'Stop Connecting',
                style: TextStyle(color: AppColors.error),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppColors.error),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Device card ──────────────────────────────────────────────────────────

class _DeviceCard extends StatelessWidget {
  final DeviceModel device;
  final VoidCallback onTap;

  const _DeviceCard({
    required this.device,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(AppConstants.defaultBorderRadius),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius:
            BorderRadius.circular(AppConstants.defaultBorderRadius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.bluetooth_searching,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (device.rssi != 0)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.signal_cellular_alt,
                                  size: 14,
                                  color: AppColors.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                '${device.rssi} dBm',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        _badge('BLE Discovered',
                            AppColors.primary.withOpacity(0.08),
                            AppColors.primary),
                        _wifiDirectBadge(),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios,
                  size: 16, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(String label, Color bg, Color fg) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 9, fontWeight: FontWeight.bold, color: fg),
        ),
      );

  Widget _wifiDirectBadge() => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering, size: 10, color: Colors.green),
            SizedBox(width: 3),
            Text(
              'Wi-Fi Direct',
              style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Colors.green),
            ),
          ],
        ),
      );
}
