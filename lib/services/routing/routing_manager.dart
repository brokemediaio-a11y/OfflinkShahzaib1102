import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import '../../models/message_model.dart';
import '../../utils/logger.dart';
import '../storage/device_storage.dart';
import '../storage/pending_message_storage.dart';
import '../storage/message_storage.dart';
import '../communication/transport_manager.dart';

/// Manages message routing, deduplication, forwarding, and delivery
/// in the OffLink mesh network.
///
/// Routing pipeline for every incoming/outgoing message:
///
///   1. Deduplication     — drop already-processed messages (prevent loops)
///   2. TTL check         — drop messages that exceeded hop limit
///   3. Local delivery    — if finalReceiverId == myId, deliver + emit ACK
///   4. Forward           — otherwise, increment hop and broadcast to neighbors
///   5. Store-and-forward — if no neighbors, queue in pending_messages
class RoutingManager {
  static final RoutingManager _instance = RoutingManager._internal();
  factory RoutingManager() => _instance;
  RoutingManager._internal();

  /// Cache of already-processed message IDs (deduplication).
  final Set<String> _processedMessageIds = <String>{};

  static const int _maxProcessedMessages = 1000;

  // ── Outgoing streams ─────────────────────────────────────────────

  /// Messages delivered to this device (for ChatProvider / UI).
  final _localMessageController = StreamController<MessageModel>.broadcast();
  Stream<MessageModel> get localMessages => _localMessageController.stream;

  /// Delivery ACKs to be sent back over the active connection.
  ///
  /// Format: { '__type': '__delivery_ack__', 'messageId': ..., 'originalSenderId': ... }
  final _deliveryAckController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get deliveryAcks =>
      _deliveryAckController.stream;

  // ── Identity ─────────────────────────────────────────────────────

  String get _myDeviceId => DeviceStorage.getDeviceId();

  // ═══════════════════════════════════════════════════════════════════
  // Main entry point
  // ═══════════════════════════════════════════════════════════════════

  /// Route a message through the mesh.
  ///
  /// [message]       — the message to route.
  /// [senderPeerId]  — UUID of the peer who sent this message to us
  ///                   (used to avoid echoing it back to the sender).
  ///
  /// Returns `true` if the message was handled (delivered or forwarded).
  Future<bool> routeMessage(
    MessageModel message, {
    String? senderPeerId,
  }) async {
    try {
      Logger.info(
          'RoutingManager: routing message ${message.messageId} '
          '(from: ${message.originalSenderId} → to: ${message.finalReceiverId}, '
          'hop: ${message.hopCount}/${message.maxHops})');

      // Step 1: Deduplication
      if (_isDuplicate(message.messageId)) {
        Logger.debug(
            'RoutingManager: duplicate message ${message.messageId} — dropped');
        return false;
      }
      _markAsProcessed(message.messageId);

      // Step 2: Check if this message is for this device
      if (_isForThisDevice(message)) {
        Logger.info(
            'RoutingManager: ✅ message ${message.messageId} is for this device — delivering locally');
        _deliverLocally(message);
        return true;
      }

      // Step 3: TTL check — drop if hop limit exceeded
      if (message.hopCount >= message.maxHops) {
        Logger.warning(
            'RoutingManager: ⛔ message ${message.messageId} exceeded hop limit '
            '(${message.hopCount}/${message.maxHops}) — dropped');
        return false;
      }

      // Step 4: Forward or store
      Logger.info(
          'RoutingManager: message ${message.messageId} needs forwarding '
          '(hop ${message.hopCount}/${message.maxHops})');
      await _forwardToNeighbors(message, senderPeerId: senderPeerId);
      return true;
    } catch (e, st) {
      Logger.error('RoutingManager: error routing message', e, st);
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Local delivery
  // ═══════════════════════════════════════════════════════════════════

  void _deliverLocally(MessageModel message) {
    // 1. Emit to ChatProvider / ConnectionNotifier
    _localMessageController.add(message);

    // 2. Emit a delivery ACK so the sender can update message status
    final ack = {
      '__type': '__delivery_ack__',
      'messageId': message.messageId,
      'originalSenderId': message.originalSenderId,
      'finalReceiverId': message.finalReceiverId,
      'ackSenderId': _myDeviceId,
      'timestamp': DateTime.now().toIso8601String(),
    };
    _deliveryAckController.add(ack);

    Logger.info(
        'RoutingManager: 📨 delivered message ${message.messageId} locally; '
        'ACK queued for originalSender=${message.originalSenderId}');
  }

  // ═══════════════════════════════════════════════════════════════════
  // Forwarding / Store-and-Forward
  // ═══════════════════════════════════════════════════════════════════

  /// Forward a message to all neighbors (except the peer we received it from).
  ///
  /// If no usable neighbors exist, the message is saved to [PendingMessageStorage]
  /// and will be flushed when a new connection becomes available.
  Future<void> _forwardToNeighbors(
    MessageModel message, {
    String? senderPeerId,
  }) async {
    // Increment hop count before forwarding
    final forwardedMessage = message.copyWith(
      hopCount: message.hopCount + 1,
      senderPeerId: _myDeviceId,
    );

    // Get active neighbors from TransportManager
    final allNeighbors = TransportManager().getNeighbors();

    // Exclude the peer we received this from (prevent echoing)
    final targets = allNeighbors
        .where((p) => p.peerId != senderPeerId && p.socketActive)
        .toList();

    if (targets.isEmpty) {
      // No usable neighbors — queue for store-and-forward
      Logger.info(
          'RoutingManager: no neighbors to forward to — storing message '
          '${message.messageId} in pending queue');
      await PendingMessageStorage.savePendingMessage(forwardedMessage);
      return;
    }

    // Serialize once, send to all eligible neighbors
    final messageJson = jsonEncode(forwardedMessage.toJson());
    final messageBytes = Uint8List.fromList(utf8.encode(messageJson));

    int forwarded = 0;
    for (final neighbor in targets) {
      final sent =
          await TransportManager().sendToPeer(neighbor.peerId, messageBytes);
      if (sent) {
        forwarded++;
        // Update local storage status to 'relayed' if we originally sent it
        if (forwardedMessage.originalSenderId == _myDeviceId) {
          await MessageStorage.updateMessageStatus(
            forwardedMessage.id,
            MessageStatus.relayed,
          );
        }
      }
    }

    if (forwarded == 0) {
      // All sends failed — save to pending as fallback
      Logger.warning(
          'RoutingManager: all forward attempts failed — queuing message '
          '${message.messageId} as pending');
      await PendingMessageStorage.savePendingMessage(forwardedMessage);
    } else {
      Logger.info(
          'RoutingManager: ↗️ forwarded message ${message.messageId} '
          'to $forwarded/${targets.length} neighbor(s) '
          '(hop now: ${forwardedMessage.hopCount})');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // Helper predicates
  // ═══════════════════════════════════════════════════════════════════

  bool _isDuplicate(String messageId) =>
      _processedMessageIds.contains(messageId);

  void _markAsProcessed(String messageId) {
    _processedMessageIds.add(messageId);
    // Prevent unbounded growth — remove oldest entry when limit reached
    if (_processedMessageIds.length > _maxProcessedMessages) {
      _processedMessageIds.remove(_processedMessageIds.first);
    }
  }

  bool _isForThisDevice(MessageModel message) =>
      message.finalReceiverId == _myDeviceId;

  // ═══════════════════════════════════════════════════════════════════
  // Utilities
  // ═══════════════════════════════════════════════════════════════════

  void clearProcessedMessages() {
    _processedMessageIds.clear();
    Logger.info('RoutingManager: cleared processed message cache');
  }

  Map<String, dynamic> getStatistics() {
    return {
      'processedMessages': _processedMessageIds.length,
      'maxProcessedMessages': _maxProcessedMessages,
      'myDeviceId': _myDeviceId,
      'pendingMessages': PendingMessageStorage.getPendingCount(),
    };
  }

  void dispose() {
    _localMessageController.close();
    _deliveryAckController.close();
    _processedMessageIds.clear();
  }
}
