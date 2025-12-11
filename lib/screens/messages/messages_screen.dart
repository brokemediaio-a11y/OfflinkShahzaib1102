import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/app_colors.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../models/conversation_model.dart';
import '../../providers/conversations_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/device_provider.dart';
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
    // Refresh conversations when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(conversationsProvider.notifier).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final conversationsState = ref.watch(conversationsProvider);
    final connectionState = ref.watch(connectionProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Messages'),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
      ),
      body: conversationsState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : conversationsState.conversations.isEmpty
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
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async {
                    ref.read(conversationsProvider.notifier).refresh();
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(AppConstants.defaultPadding),
                    itemCount: conversationsState.conversations.length,
                    itemBuilder: (context, index) {
                      final conversation = conversationsState.conversations[index];
                      return _ConversationTile(
                        conversation: conversation,
                        isConnected: connectionState.connectedDevice?.id == conversation.deviceId,
                        onTap: () async {
                          // Mark as read
                          ref.read(conversationsProvider.notifier).markAsRead(conversation.deviceId);
                          
                          // Create device model
                          final device = DeviceModel(
                            id: conversation.deviceId,
                            name: conversation.deviceName,
                            address: conversation.deviceId,
                            type: DeviceType.ble,
                            rssi: 0,
                            lastSeen: conversation.lastMessageTime,
                          );
                          
                          // Check if already connected to this device
                          final connectionState = ref.read(connectionProvider);
                          final isConnected = connectionState.state == ConnectionStateType.connected &&
                              connectionState.connectedDevice?.id == conversation.deviceId;
                          
                          if (!isConnected) {
                            // Show connect dialog
                            final shouldConnect = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Connect to Device'),
                                content: Text('Connect to ${conversation.deviceName} to send messages?'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(false),
                                    child: const Text('Cancel'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () => Navigator.of(context).pop(true),
                                    child: const Text('Connect'),
                                  ),
                                ],
                              ),
                            );
                            
                            if (shouldConnect == true && context.mounted) {
                              // Show connecting dialog
                              showDialog(
                                context: context,
                                barrierDismissible: false,
                                builder: (context) => const Center(
                                  child: Card(
                                    child: Padding(
                                      padding: EdgeInsets.all(20),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          CircularProgressIndicator(),
                                          SizedBox(height: 16),
                                          Text('Connecting to device...'),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                              
                              // Try to connect
                              final connectionNotifier = ref.read(connectionProvider.notifier);
                              final deviceNotifier = ref.read(deviceProvider.notifier);
                              
                              // First, scan for devices
                              await deviceNotifier.startScan();
                              await Future.delayed(const Duration(seconds: 5));
                              
                              // Get discovered devices
                              final discoveredDevices = ref.read(deviceProvider).discoveredDevices;
                              Logger.info('Found ${discoveredDevices.length} devices during scan');
                              for (final d in discoveredDevices) {
                                Logger.info('Discovered device: id=${d.id}, address=${d.address}, name=${d.name}');
                              }
                              Logger.info('Looking for device: conversation.deviceId=${conversation.deviceId}, conversation.deviceName=${conversation.deviceName}');
                              
                              // Find the target device - improved matching logic
                              DeviceModel? foundDevice;
                              
                              // First, try exact matches
                              for (final d in discoveredDevices) {
                                if (d.id == conversation.deviceId || 
                                    d.address == conversation.deviceId ||
                                    d.id == conversation.deviceName ||
                                    d.address == conversation.deviceName) {
                                  foundDevice = d;
                                  Logger.info('Matched device by exact ID/address: ${d.name} (${d.address})');
                                  break;
                                }
                              }
                              
                              // If no exact match, try matching by name (especially for "Offlink" devices)
                              if (foundDevice == null) {
                                for (final d in discoveredDevices) {
                                  if (d.name.toLowerCase().contains('offlink') || 
                                      conversation.deviceName.toLowerCase().contains('offlink')) {
                                    // If both are Offlink devices, match by name
                                    if (d.name == conversation.deviceName || 
                                        conversation.deviceName.contains(d.name) ||
                                        d.name.contains(conversation.deviceName)) {
                                      foundDevice = d;
                                      Logger.info('Matched device by name (Offlink): ${d.name} (${d.address})');
                                      break;
                                    }
                                  }
                                }
                              }
                              
                              // If still no match and we have only one Offlink device, use it
                              if (foundDevice == null) {
                                final offlinkDevices = discoveredDevices.where((d) => 
                                  d.name.toLowerCase().contains('offlink')
                                ).toList();
                                
                                if (offlinkDevices.length == 1) {
                                  foundDevice = offlinkDevices.first;
                                  Logger.info('Matched single Offlink device: ${foundDevice.name} (${foundDevice.address})');
                                }
                              }
                              
                              // Last resort: if conversation.deviceId looks like a MAC address, try matching
                              if (foundDevice == null && 
                                  conversation.deviceId.contains(':') && 
                                  conversation.deviceId.length == 17) {
                                for (final d in discoveredDevices) {
                                  if (d.address == conversation.deviceId || d.id == conversation.deviceId) {
                                    foundDevice = d;
                                    Logger.info('Matched device by MAC address: ${d.name} (${d.address})');
                                    break;
                                  }
                                }
                              }
                              
                              await deviceNotifier.stopScan();
                              
                              // Close connecting dialog
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                              
                              if (foundDevice != null) {
                                final connected = await connectionNotifier.connectToDevice(foundDevice);
                                
                                if (connected && context.mounted) {
                                  // Update conversation's deviceId to match the connected device
                                  // This ensures consistency when sending messages
                                  final conversationsNotifier = ref.read(conversationsProvider.notifier);
                                  try {
                                    // Refresh conversations to ensure we have the latest state
                                    conversationsNotifier.refresh();
                                  } catch (e) {
                                    Logger.warning('Error refreshing conversations: $e');
                                  }
                                  
                                  // IMPORTANT: Create a DeviceModel using the conversation's deviceId (UUID from received message)
                                  // This ensures we use the same device ID format that was used when the message was received
                                  // The foundDevice might have a MAC address, but we need to use the UUID from the conversation
                                  final chatDevice = DeviceModel(
                                    id: conversation.deviceId, // Use conversation's deviceId (UUID from received message)
                                    name: foundDevice.name,
                                    address: foundDevice.address,
                                    type: foundDevice.type,
                                    rssi: foundDevice.rssi,
                                    isConnected: true,
                                  );
                                  
                                  Logger.info('Opening chat with device: id=${chatDevice.id}, name=${chatDevice.name}, address=${chatDevice.address}');
                                  Logger.info('Conversation deviceId: ${conversation.deviceId}, Found device id: ${foundDevice.id}');
                                  
                                  // Navigate to chat screen with device using conversation's deviceId
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => ChatScreen(device: chatDevice),
                                    ),
                                  );
                                } else if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Failed to connect. Please try again.'),
                                      backgroundColor: AppColors.error,
                                    ),
                                  );
                                }
                              } else {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Device not found. Please ensure device is nearby and advertising.'),
                                      backgroundColor: AppColors.error,
                                    ),
                                  );
                                }
                              }
                            }
                          } else {
                            // Already connected, open chat screen
                            // IMPORTANT: Use conversation's deviceId to ensure consistency
                            final chatDevice = DeviceModel(
                              id: conversation.deviceId, // Use conversation's deviceId (UUID from received message)
                              name: device.name,
                              address: device.address,
                              type: device.type,
                              rssi: device.rssi,
                              isConnected: true,
                            );
                            
                            Logger.info('Opening chat (already connected): id=${chatDevice.id}, name=${chatDevice.name}');
                            
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(device: chatDevice),
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
                ),
    );
  }
}

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
              // Avatar
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
                  isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                  color: isConnected ? AppColors.primary : AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 16),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.deviceName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isConnected)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
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
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        conversation.unreadCount > 99 ? '99+' : '${conversation.unreadCount}',
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

    if (difference.inDays == 0) {
      return DateFormat('HH:mm').format(timestamp);
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return DateFormat('EEE').format(timestamp);
    } else {
      return DateFormat('MM/dd').format(timestamp);
    }
  }
}
