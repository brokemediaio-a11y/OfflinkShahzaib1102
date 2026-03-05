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
import '../chat/chat_screen.dart';
import '../connection/connection_status_screen.dart';
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

  // Prevents showing duplicate consent dialogs for the same invitation.
  bool _invitationDialogOpen = false;

  StreamSubscription<Map<String, String>>? _invitationSubscription;

  @override
  void initState() {
    super.initState();
    // Subscribe to incoming Wi-Fi Direct invitations.
    // We must do this in initState (not build) to avoid multiple subscriptions.
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

  /// Called when another device sends us a Wi-Fi Direct connection invitation.
  Future<void> _onIncomingInvitation(Map<String, String> payload) async {
    if (!mounted || _invitationDialogOpen) return;

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
                style: const TextStyle(fontSize: 15, color: AppColors.textPrimary),
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
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    _invitationDialogOpen = false;
    if (!mounted) return;

    final notifier = ref.read(connectionProvider.notifier);
    if (accepted == true) {
      await notifier.acceptInvitation();
      // Chat screen will open automatically when SOCKET_CONNECTED fires via
      // the existing ref.listen in build().
    } else {
      await notifier.rejectInvitation();
    }
  }

  Future<void> _connectToDevice(DeviceModel device) async {
    // Remember the intended peer so ref.listen can navigate when the socket
    // is confirmed open (SOCKET_CONNECTED).  Do NOT navigate here.
    _pendingConnectionDevice = device;

    // Show a persistent "connecting…" snackbar — dismissed when state changes.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Text('Connecting to ${device.name} via Wi-Fi Direct…'),
          ],
        ),
        duration: const Duration(seconds: 60),
        backgroundColor: AppColors.primary,
      ),
    );

    final connectionNotifier = ref.read(connectionProvider.notifier);
    final started = await connectionNotifier.connectToDevice(device);

    if (!mounted) return;

    if (!started) {
      // The native layer rejected the attempt immediately.
      _pendingConnectionDevice = null;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not start Wi-Fi Direct connection to ${device.name}. '
            'Ensure Wi-Fi Direct is enabled on both devices.',
          ),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 5),
        ),
      );
    }
    // If started == true we stay in "connecting" state.
    // ref.listen (in build) will fire when state transitions to
    // ConnectionStateType.connected (i.e., socket is confirmed open).
  }

  @override
  Widget build(BuildContext context) {
    final deviceState = ref.watch(deviceProvider);
    final connectionState = ref.watch(connectionProvider);

    // ── React to Wi-Fi Direct state changes ───────────────────────────────
    // Navigate to Chat ONLY when the state machine confirms SOCKET_CONNECTED.
    // This fires from _handleWifiDirectState in ConnectionManager, which only
    // emits ConnectionState.connected when socketActive == true.
    ref.listen<ConnectionProviderState>(connectionProvider, (previous, next) {
      if (!mounted) return;

      if (previous?.state != ConnectionStateType.connected &&
          next.state == ConnectionStateType.connected) {
        // Socket confirmed open — dismiss the "connecting…" snackbar.
        ScaffoldMessenger.of(context).hideCurrentSnackBar();

        // Resolve the device to open chat with:
        //   1. Use the pending device the user tapped (has the correct UUID).
        //   2. Fall back to the connected device from state (may have generic name).
        final chatDevice = _pendingConnectionDevice ?? next.connectedDevice;
        _pendingConnectionDevice = null;

        if (chatDevice != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatScreen(device: chatDevice),
            ),
          );
        }
      } else if (next.state == ConnectionStateType.error ||
                 next.state == ConnectionStateType.disconnected) {
        // Connection failed or was lost — dismiss spinner and show error.
        ScaffoldMessenger.of(context).hideCurrentSnackBar();

        if (_pendingConnectionDevice != null &&
            next.state == ConnectionStateType.error) {
          final name = _pendingConnectionDevice!.name;
          _pendingConnectionDevice = null;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Wi-Fi Direct connection to $name failed. '
                'Ensure both devices have Wi-Fi Direct enabled.',
              ),
              backgroundColor: AppColors.error,
              duration: const Duration(seconds: 5),
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
                // Restart advertising with new name
                final connectionManager = ConnectionManager();
                await connectionManager.restartAdvertising();
              }
            },
          ),
          IconButton(
            icon: Stack(
              children: [
                const Icon(Icons.message),
                // You can add a badge here for unread count
              ],
            ),
            tooltip: 'Messages',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const MessagesScreen(),
                ),
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
                    builder: (_) => ChatScreen(device: connectionState.connectedDevice!),
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
                        builder: (_) => ChatScreen(device: connectionState.connectedDevice!),
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
                      builder: (_) => const ConnectionStatusScreen(),
                    ),
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
                      deviceState.isScanning ? Icons.stop : Icons.search,
                    ),
                    label: Text(
                      deviceState.isScanning
                          ? AppStrings.stopScan
                          : AppStrings.scanDevices,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.textLight,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppConstants.defaultBorderRadius),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── BLE scanning indicator ────────────────────────────────
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

          // ── Wi-Fi Direct connection status banner ─────────────────
          if (connectionState.state == ConnectionStateType.connecting)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.orange.withOpacity(0.15),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Connecting via Wi-Fi Direct…',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (connectionState.state == ConnectionStateType.connected &&
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
                      'Connected to '
                      '${connectionState.connectedDevice!.name} '
                      'via Wi-Fi Direct',
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
                    padding: const EdgeInsets.all(AppConstants.defaultPadding),
                    itemCount: deviceState.discoveredDevices.length,
                    itemBuilder: (context, index) {
                      final device = deviceState.discoveredDevices[index];
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
        borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Device avatar: BLE icon (all discovered via BLE)
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
                    // Device name
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
                        // RSSI badge
                        if (device.rssi != 0)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.signal_cellular_alt,
                                size: 14,
                                color: AppColors.textSecondary,
                              ),
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
                        // "BLE Discovered" badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            'BLE Discovered',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary,
                            ),
                          ),
                        ),
                        // "Wi-Fi Direct" hint badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.green.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.wifi_tethering,
                                  size: 10, color: Colors.green),
                              SizedBox(width: 3),
                              Text(
                                'Wi-Fi Direct',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.green,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
