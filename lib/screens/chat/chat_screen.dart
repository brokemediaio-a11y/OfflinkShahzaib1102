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

  // ── Connect ────────────────────────────────────────────────────────

  Future<void> _connectToDevice() async {
    final connectionNotifier = ref.read(connectionProvider.notifier);
    final deviceNotifier = ref.read(deviceProvider.notifier);

    if (mounted) setState(() {});

    await deviceNotifier.startScan();
    await Future.delayed(const Duration(seconds: 5));

    final discoveredDevices = ref.read(deviceProvider).discoveredDevices;
    Logger.info('Found ${discoveredDevices.length} devices during scan');

    DeviceModel? foundDevice;

    // Exact UUID match
    for (final d in discoveredDevices) {
      if (d.id == widget.device.id) {
        foundDevice = d;
        break;
      }
    }

    // Fallback: name match
    if (foundDevice == null) {
      for (final d in discoveredDevices) {
        if (d.name == widget.device.name) {
          foundDevice = d;
          break;
        }
      }
    }

    // Fallback: single "Offlink" device
    if (foundDevice == null) {
      final offlink = discoveredDevices
          .where((d) => d.name.toLowerCase().contains('offlink'))
          .toList();
      if (offlink.length == 1) foundDevice = offlink.first;
    }

    await deviceNotifier.stopScan();

    if (foundDevice != null) {
      final connected = await connectionNotifier.connectToDevice(foundDevice);
      if (connected && mounted) {
        final chatNotifier =
            ref.read(chatProvider(widget.device.id).notifier);
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
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Device not found. Message will be queued for delivery.'),
          backgroundColor: AppColors.primary,
        ),
      );
    }
  }

  // ── Send ───────────────────────────────────────────────────────────

  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    final message = _messageController.text.trim();
    _messageController.clear();

    final chatNotifier = ref.read(chatProvider(widget.device.id).notifier);
    chatNotifier.setDeviceInfo(widget.device);

    // Send (will queue as pending if offline)
    await chatNotifier.sendMessage(message, widget.device.id,
        device: widget.device);

    // Scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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

    final isConnected =
        connectionState.state == ConnectionStateType.connected;
    final isConnecting =
        connectionState.state == ConnectionStateType.connecting;

    // Load messages on first open
    if (_currentDeviceId != widget.device.id) {
      _currentDeviceId = widget.device.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final chatNotifier =
            ref.read(chatProvider(widget.device.id).notifier);
        chatNotifier.setDeviceInfo(widget.device);
        chatNotifier.loadMessagesForConversation(widget.device.id);
      });
    }

    final storedName =
        DeviceStorage.getDeviceDisplayName(widget.device.id);
    final displayName = storedName ??
        (widget.device.name != 'Unknown Device' &&
                widget.device.name != widget.device.id
            ? widget.device.name
            : widget.device.id);

    // Connection status label
    String statusLabel;
    Color statusColor;
    if (isConnected) {
      statusLabel = AppStrings.connected;
      statusColor = Colors.green;
    } else if (isConnecting) {
      statusLabel = 'Connecting…';
      statusColor = Colors.orange;
    } else {
      statusLabel = 'Offline — messages queued';
      statusColor = AppColors.textSecondary;
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(displayName),
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                Text(statusLabel, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ],
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
        actions: [
          if (!isConnected && !isConnecting)
            IconButton(
              icon: const Icon(Icons.bluetooth_searching),
              tooltip: 'Connect',
              onPressed: _connectToDevice,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Offline banner ────────────────────────────────────────
          if (!isConnected && !isConnecting)
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.amber.shade100,
              child: Row(
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: Colors.amber.shade800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Offline — messages will be queued and sent when in range.',
                      style: TextStyle(
                          fontSize: 12, color: Colors.amber.shade900),
                    ),
                  ),
                ],
              ),
            ),

          // ── Message list ──────────────────────────────────────────
          Expanded(
            child: chatState.messages.isEmpty
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
                        if (!isConnected) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Send a message — it will be delivered when\nthe peer comes into range.',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary.withOpacity(0.7),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
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

          // ── Message input (always visible) ────────────────────────
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
                        hintText: isConnected
                            ? AppStrings.typeMessage
                            : 'Type a message (will queue if offline)…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                              AppConstants.defaultBorderRadius),
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
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    AppColors.textLight),
                              ),
                            )
                          : const Icon(Icons.send, color: AppColors.textLight),
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

// ══════════════════════════════════════════════════════════════════════
// Message Bubble
// ══════════════════════════════════════════════════════════════════════

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
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSent ? AppColors.messageSent : AppColors.messageReceived,
          borderRadius:
              BorderRadius.circular(AppConstants.defaultBorderRadius),
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
                if (isSent) ...[
                  const SizedBox(width: 4),
                  _MessageStatusIcon(message.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime timestamp) {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Widget _MessageStatusIcon(MessageStatus status) {
    IconData icon;
    Color color;
    String? tooltip;

    switch (status) {
      case MessageStatus.sending:
        icon = Icons.access_time;
        color = AppColors.messageTextSent.withOpacity(0.7);
        tooltip = 'Sending…';
        break;

      case MessageStatus.pending:
        icon = Icons.schedule_send;
        color = Colors.orange.shade300;
        tooltip = 'Pending — will send when in range';
        break;

      case MessageStatus.sent:
        icon = Icons.check;
        color = AppColors.messageTextSent.withOpacity(0.7);
        tooltip = 'Sent';
        break;

      case MessageStatus.relayed:
        icon = Icons.sync_alt;
        color = Colors.blue.shade300;
        tooltip = 'Relayed via mesh';
        break;

      case MessageStatus.delivered:
        icon = Icons.done_all;
        color = Colors.blue.shade400;
        tooltip = 'Delivered';
        break;

      case MessageStatus.failed:
        icon = Icons.error_outline;
        color = AppColors.error;
        tooltip = 'Failed';
        break;
    }

    return Tooltip(
      message: tooltip ?? '',
      child: Icon(icon, size: 12, color: color),
    );
  }
}
