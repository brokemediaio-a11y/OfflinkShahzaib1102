import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_colors.dart';
import '../../core/app_strings.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../providers/device_provider.dart';
import '../../providers/connection_provider.dart';
import '../chat/chat_screen.dart';
import '../connection/connection_status_screen.dart';
import '../messages/messages_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  
  // Remove the initState listener setup - it's not allowed there
  
  void _showConnectionDialog(DeviceModel device) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Device Connected'),
        content: Text('Connected to ${device.name}\n\nOpen chat to start messaging?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatScreen(device: device),
                ),
              );
            },
            child: const Text('Open Chat'),
          ),
        ],
      ),
    );
  }

  Future<void> _connectToDevice(DeviceModel device) async {
    final connectionNotifier = ref.read(connectionProvider.notifier);
    final connected = await connectionNotifier.connectToDevice(device);

    if (!mounted) return;

    if (connected) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(device: device),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(AppStrings.connectionError),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final deviceState = ref.watch(deviceProvider);
    final connectionState = ref.watch(connectionProvider);
    
    // Move ref.listen inside build method
    ref.listen<ConnectionProviderState>(connectionProvider, (previous, next) {
      if (previous?.state != ConnectionStateType.connected &&
          next.state == ConnectionStateType.connected &&
          next.connectedDevice != null &&
          mounted) {
        _showConnectionDialog(next.connectedDevice!);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.homeTitle),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
        actions: [
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
              icon: const Icon(Icons.chat),
              tooltip: 'Open Chat',
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
                    AppStrings.scanning,
                    style: TextStyle(color: AppColors.info),
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
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: device.type == DeviceType.ble
                      ? AppColors.primary.withOpacity(0.1)
                      : AppColors.secondary.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  device.type == DeviceType.ble
                      ? Icons.bluetooth
                      : Icons.wifi,
                  color: device.type == DeviceType.ble
                      ? AppColors.primary
                      : AppColors.secondary,
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
                    Row(
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
                        const SizedBox(width: 16),
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: device.type == DeviceType.ble
                                ? AppColors.primary.withOpacity(0.1)
                                : AppColors.secondary.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            device.type == DeviceType.ble ? 'BLE' : 'Wi-Fi',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: device.type == DeviceType.ble
                                  ? AppColors.primary
                                  : AppColors.secondary,
                            ),
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
