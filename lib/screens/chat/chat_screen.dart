import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_colors.dart';
import '../../core/app_strings.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../models/message_model.dart';
import '../../providers/chat_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/device_provider.dart';
import '../../services/storage/device_storage.dart';
import '../../utils/logger.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final DeviceModel device;

  const ChatScreen({super.key, required this.device});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String? _currentDeviceId;

  @override
  void initState() {
    super.initState();
    // Messages are handled globally via ConnectionNotifier
    // Messages will be loaded from storage when screen opens
  }

  Future<void> _connectToDevice() async {
    final connectionNotifier = ref.read(connectionProvider.notifier);
    final deviceNotifier = ref.read(deviceProvider.notifier);
    
    // Show connecting indicator
    if (mounted) {
      setState(() {});
    }
    
    // Start scanning for devices
    await deviceNotifier.startScan();
    await Future.delayed(const Duration(seconds: 5));
    
    // Get discovered devices
    final discoveredDevices = ref.read(deviceProvider).discoveredDevices;
    Logger.info('Found ${discoveredDevices.length} devices during scan');
    for (final d in discoveredDevices) {
      Logger.info('Discovered device: id=${d.id}, address=${d.address}, name=${d.name}');
    }
    Logger.info('Looking for device: widget.device.id=${widget.device.id}, widget.device.address=${widget.device.address}, widget.device.name=${widget.device.name}');
    
    // Find the target device - improved matching logic
    DeviceModel? foundDevice;
    
    // First, try exact matches by UUID (primary identifier)
    for (final d in discoveredDevices) {
      if (d.id == widget.device.id) {
        foundDevice = d;
        Logger.info('Matched device by UUID: ${d.name} (UUID: ${d.id})');
        break;
      }
    }
    
    // Fallback: try matching by name if UUID match failed
    if (foundDevice == null) {
      for (final d in discoveredDevices) {
        if (d.name == widget.device.name) {
          foundDevice = d;
          Logger.info('Matched device by name: ${d.name} (UUID: ${d.id})');
          break;
        }
      }
    }
    
    // If no exact match, try matching by name (especially for "Offlink" devices)
    // This is a fallback - UUID matching should be primary
    if (foundDevice == null) {
      for (final d in discoveredDevices) {
        if (d.name.toLowerCase().contains('offlink') || 
            widget.device.name.toLowerCase().contains('offlink')) {
          // If both are Offlink devices, match by name
          if (d.name == widget.device.name || 
              widget.device.name.contains(d.name) ||
              d.name.contains(widget.device.name)) {
            foundDevice = d;
            Logger.info('Matched device by name (Offlink): ${d.name} (UUID: ${d.id})');
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
        Logger.info('Matched single Offlink device: ${foundDevice.name} (UUID: ${foundDevice.id})');
      }
    }
    
    await deviceNotifier.stopScan();
    
    if (foundDevice != null) {
      final connected = await connectionNotifier.connectToDevice(foundDevice);
      if (connected && mounted) {
        // Update device info in chat provider
        final chatNotifier = ref.read(chatProvider(widget.device.id).notifier);
        chatNotifier.setDeviceInfo(foundDevice);
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to ${foundDevice.name}'),
            backgroundColor: AppColors.primary,
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to connect. Please try again.'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Device not found. Please ensure device is nearby and advertising.'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;
    
    // Check if connected
    final connectionState = ref.read(connectionProvider);
    if (connectionState.state != ConnectionStateType.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please connect to device first'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    final message = _messageController.text.trim();
    _messageController.clear();

    final chatNotifier = ref.read(chatProvider(widget.device.id).notifier);
    // Set device info
    chatNotifier.setDeviceInfo(widget.device);
    // Send message
    await chatNotifier.sendMessage(message, widget.device.id, device: widget.device);

    // Scroll to bottom
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider(widget.device.id));
    final connectionState = ref.watch(connectionProvider);

    // Load messages for this conversation on first build
    if (_currentDeviceId != widget.device.id) {
      _currentDeviceId = widget.device.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final chatNotifier = ref.read(chatProvider(widget.device.id).notifier);
        // Set device info for auto-connection
        chatNotifier.setDeviceInfo(widget.device);
        chatNotifier.loadMessagesForConversation(widget.device.id);
      });
    }

    // Get stored device name or use device name from widget
    final storedName = DeviceStorage.getDeviceDisplayName(widget.device.id);
    final displayName = storedName ?? (widget.device.name != 'Unknown Device' && widget.device.name != widget.device.id ? widget.device.name : widget.device.id);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(displayName),
            Text(
              connectionState.state == ConnectionStateType.connected
                  ? AppStrings.connected
                  : AppStrings.disconnected,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
      ),
      body: Column(
        children: [
          // Messages List
          Expanded(
            child: chatState.messages.isEmpty && connectionState.state != ConnectionStateType.connected
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.bluetooth_disabled,
                          size: 64,
                          color: AppColors.textSecondary.withOpacity(0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Not Connected',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Connect to ${widget.device.name} to send messages',
                          style: TextStyle(
                            fontSize: 14,
                            color: AppColors.textSecondary,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: connectionState.state == ConnectionStateType.connecting
                              ? null
                              : _connectToDevice,
                          icon: connectionState.state == ConnectionStateType.connecting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.bluetooth),
                          label: Text(
                            connectionState.state == ConnectionStateType.connecting
                                ? 'Connecting...'
                                : 'Connect to Device',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: AppColors.textLight,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : chatState.messages.isEmpty
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
                              AppStrings.noMessages,
                              style: TextStyle(
                                fontSize: 16,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(AppConstants.defaultPadding),
                        itemCount: chatState.messages.length,
                        itemBuilder: (context, index) {
                          final message = chatState.messages[index];
                          return _MessageBubble(message: message);
                        },
                      ),
          ),
          // Message Input - Only show if connected
          if (connectionState.state == ConnectionStateType.connected)
            Container(
              padding: const EdgeInsets.all(AppConstants.defaultPadding),
              decoration: BoxDecoration(
                color: AppColors.surface,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.textSecondary.withOpacity(0.1),
                    blurRadius: 4,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: SafeArea(
                child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _messageController,
                              decoration: InputDecoration(
                                hintText: AppStrings.typeMessage,
                                border: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppConstants.defaultBorderRadius),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: AppColors.background,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                              ),
                              maxLines: null,
                              textCapitalization: TextCapitalization.sentences,
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              onPressed: chatState.isSending ? null : _sendMessage,
                              icon: chatState.isSending
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(AppColors.textLight),
                                      ),
                                    )
                                  : const Icon(
                                      Icons.send,
                                      color: AppColors.textLight,
                                    ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final MessageModel message;

  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isSent = message.isSent;

    return Align(
      alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSent ? AppColors.messageSent : AppColors.messageReceived,
          borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.content,
              style: TextStyle(
                fontSize: 14,
                color: isSent
                    ? AppColors.messageTextSent
                    : AppColors.messageTextReceived,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(message.timestamp),
                  style: TextStyle(
                    fontSize: 10,
                    color: isSent
                        ? AppColors.messageTextSent.withOpacity(0.7)
                        : AppColors.messageTextReceived.withOpacity(0.7),
                  ),
                ),
                const SizedBox(width: 4),
                if (isSent) _MessageStatusIcon(message.status),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime timestamp) {
    final hour = timestamp.hour.toString().padLeft(2, '0');
    final minute = timestamp.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Widget _MessageStatusIcon(MessageStatus status) {
    IconData icon;
    Color color;

    switch (status) {
      case MessageStatus.sending:
        icon = Icons.access_time;
        color = AppColors.messageTextSent.withOpacity(0.7);
        break;
      case MessageStatus.sent:
        icon = Icons.check;
        color = AppColors.messageTextSent.withOpacity(0.7);
        break;
      case MessageStatus.delivered:
        icon = Icons.done_all;
        color = AppColors.messageTextSent.withOpacity(0.7);
        break;
      case MessageStatus.failed:
        icon = Icons.error_outline;
        color = AppColors.error;
        break;
    }

    return Icon(icon, size: 12, color: color);
  }
}




