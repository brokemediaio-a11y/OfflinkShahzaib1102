import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_colors.dart';
import '../../core/app_strings.dart';
import '../../core/constants.dart';
import '../../models/device_model.dart';
import '../../models/message_model.dart';
import '../../providers/chat_provider.dart';
import '../../providers/connection_provider.dart';
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

  // Tracks the last known message count so we can detect new arrivals.
  int _lastMessageCount = 0;

  // Whether the reconnecting dialog is currently on screen.
  bool _reconnectDialogOpen = false;

  // ── Reconnect dialog ────────────────────────────────────────────────

  void _showReconnectingDialog() {
    if (_reconnectDialogOpen) return;
    _reconnectDialogOpen = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ReconnectingDialog(
        deviceName: widget.device.name,
        onStop: () async {
          Navigator.of(ctx).pop();
          await ref.read(connectionProvider.notifier).cancelConnection();
        },
      ),
    ).then((_) {
      if (mounted) _reconnectDialogOpen = false;
    });
  }

  void _dismissReconnectDialog() {
    // Always clear the flag — regardless of whether the dialog is physically open.
    // Removes the race condition where connected state fires before the dialog
    // finishes opening (and the old guard caused a permanent stuck dialog).
    _reconnectDialogOpen = false;
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  // ── Connect ────────────────────────────────────────────────────────

  Future<void> _connectToDevice() async {
    final connectionState = ref.read(connectionProvider);

    // Already connected to this peer — nothing to do.
    if (connectionState.state == ConnectionStateType.connected &&
        connectionState.connectedDevice?.id == widget.device.id) {
      Logger.info(
          'ChatScreen: already connected to ${widget.device.name} — skipping');
      return;
    }

    // Another connection attempt already in flight — don't stack requests.
    if (connectionState.state == ConnectionStateType.connecting) {
      Logger.info('ChatScreen: connection attempt already in progress');
      return;
    }

    final connectionNotifier = ref.read(connectionProvider.notifier);
    final started = await connectionNotifier.connectToDevice(widget.device);

    if (!mounted) return;

    if (started) {
      // Re-read state AFTER connectToDevice() returns.
      //
      // connectToDevice() may re-emit ConnectionState.connected synchronously
      // (e.g. when the peer was already connected, or when the native layer
      // re-established the link during the await). In that case ref.listen
      // fires BEFORE this point — there is no dialog open yet, so the dismiss
      // call inside the listener is a no-op, and the dialog would be stuck
      // forever if we unconditionally call _showReconnectingDialog() here.
      //
      // Solution: check current state immediately after the await and only
      // show the dialog if we are still in the connecting/not-yet-connected
      // state.
      final stateAfter = ref.read(connectionProvider);
      final alreadyConnected = stateAfter.state == ConnectionStateType.connected &&
          stateAfter.connectedDevice?.id == widget.device.id;
      if (!alreadyConnected) {
        _showReconnectingDialog();
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Could not reach ${widget.device.name}. '
              'Ensure both devices have Wi-Fi Direct enabled.'),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 5),
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

    _scrollToBottom();
  }

  /// Smoothly scroll to the most recent message.
  void _scrollToBottom() {
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

    // Only count as "connected" if the active connection is specifically to THIS device.
    // Prevents showing "Connected" in B's chat while A is actually connected to C.
    final isConnectedToThis =
        connectionState.state == ConnectionStateType.connected &&
        connectionState.connectedDevice?.id == widget.device.id;

    // Safety dismiss: guard against the async race where connected state was
    // re-emitted inside connectToDevice() (before our await returned), causing
    // ref.listen to fire with no dialog on screen.  If we are now connected to
    // this peer AND the dialog flag is still set, close it on the next frame.
    if (isConnectedToThis && _reconnectDialogOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _dismissReconnectDialog());
    }

    // Show connecting spinner only when an attempt is in flight.
    // If connected to a DIFFERENT device, treat this chat as offline (not connecting).
    final isConnecting = connectionState.state == ConnectionStateType.connecting;

    // Dismiss reconnect dialog when socket opens or attempt ends.
    ref.listen<ConnectionProviderState>(connectionProvider, (prev, next) {
      if (!mounted) return;

      final nowConnectedToThis =
          next.state == ConnectionStateType.connected &&
          next.connectedDevice?.id == widget.device.id;

      if (nowConnectedToThis) {
        _dismissReconnectDialog();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to ${widget.device.name}'),
            backgroundColor: AppColors.primary,
            duration: const Duration(seconds: 2),
          ),
        );
      } else if (next.state == ConnectionStateType.error ||
          (next.state == ConnectionStateType.disconnected &&
              prev?.state == ConnectionStateType.connecting)) {
        _dismissReconnectDialog();
        final errorMsg =
            ref.read(connectionProvider.notifier).lastConnectionError ??
            'Connection to ${widget.device.name} failed. Try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMsg),
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    });

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

    // Auto-scroll whenever a new message is added (sent or received).
    final currentCount = chatState.messages.length;
    if (currentCount > _lastMessageCount) {
      _lastMessageCount = currentCount;
      _scrollToBottom();
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
    if (isConnectedToThis) {
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
          if (!isConnectedToThis && !isConnecting)
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
          if (!isConnectedToThis && !isConnecting)
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
                        if (!isConnectedToThis) ...[
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
                        hintText: isConnectedToThis
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
// Reconnecting dialog
// ══════════════════════════════════════════════════════════════════════

class _ReconnectingDialog extends StatelessWidget {
  final String deviceName;
  final VoidCallback onStop;

  const _ReconnectingDialog({
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
          const Text(
            'Reconnecting…',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
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
            'Trying to re-establish the Wi-Fi Direct link.\nThis may take up to 30 seconds.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onStop,
              icon: const Icon(Icons.stop_circle_outlined,
                  color: AppColors.error),
              label: const Text(
                'Stop',
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
