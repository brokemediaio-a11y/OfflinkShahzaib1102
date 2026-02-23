import 'dart:async';
import '../../models/message_model.dart';
import '../../utils/logger.dart';
import '../storage/device_storage.dart';

/// Manages message routing, deduplication, and forwarding in the mesh network
/// 
/// This layer is responsible for:
/// - Message deduplication (prevent infinite loops)
/// - TTL/hop count management
/// - Deciding whether to deliver locally or forward
/// - (Future) Forwarding messages to neighbors
/// 
/// IMPORTANT: Forwarding is currently DISABLED - messages are only delivered locally
class RoutingManager {
  static final RoutingManager _instance = RoutingManager._internal();
  factory RoutingManager() => _instance;
  RoutingManager._internal();

  /// Set of processed message IDs to prevent duplicate processing
  /// Messages are identified by their messageId field
  final Set<String> _processedMessageIds = <String>{};

  /// Maximum size of the processed messages set (prevent unbounded growth)
  static const int _maxProcessedMessages = 1000;

  /// Stream controller for locally delivered messages
  final _localMessageController = StreamController<MessageModel>.broadcast();

  /// Stream of messages that should be delivered to this device
  Stream<MessageModel> get localMessages => _localMessageController.stream;

  /// Get the device ID for this device
  String get _myDeviceId => DeviceStorage.getDeviceId();

  /// Route an incoming or outgoing message through the mesh network
  /// 
  /// This is the main entry point for all messages (sent or received)
  /// 
  /// Returns true if the message was processed successfully
  Future<bool> routeMessage(MessageModel message) async {
    try {
      Logger.info('RoutingManager: Processing message ${message.messageId}');
      Logger.debug('  From: ${message.originalSenderId} → To: ${message.finalReceiverId}');
      Logger.debug('  Hop: ${message.hopCount}/${message.maxHops}');

      // Step 1: Check for duplicate messages (deduplication)
      if (_isDuplicate(message.messageId)) {
        Logger.info('RoutingManager: Ignoring duplicate message ${message.messageId}');
        return false;
      }

      // Step 2: Mark message as processed
      _markAsProcessed(message.messageId);

      // Step 3: Check if message is for this device
      if (_isForThisDevice(message)) {
        Logger.info('RoutingManager: Message is for this device, delivering locally');
        _deliverLocally(message);
        return true;
      }

      // Step 4: Check if message should be forwarded
      if (_shouldForwardMessage(message)) {
        Logger.info('RoutingManager: Message should be forwarded (hopCount: ${message.hopCount}/${message.maxHops})');
        // IMPORTANT: Forwarding is currently DISABLED for FYP stability
        // When ready to enable multi-hop, implement _forwardToNeighbors()
        await _forwardToNeighbors(message);
        return true;
      }

      // Step 5: Message has exceeded hop limit or other drop condition
      Logger.warning('RoutingManager: Dropping message ${message.messageId} (hopCount: ${message.hopCount}/${message.maxHops})');
      return false;
    } catch (e, stackTrace) {
      Logger.error('RoutingManager: Error routing message', e, stackTrace);
      return false;
    }
  }

  /// Check if a message has already been processed (deduplication)
  bool _isDuplicate(String messageId) {
    return _processedMessageIds.contains(messageId);
  }

  /// Mark a message as processed
  void _markAsProcessed(String messageId) {
    _processedMessageIds.add(messageId);

    // Prevent unbounded growth - remove oldest entries if limit exceeded
    // In a production system, you might use a time-based expiry or LRU cache
    if (_processedMessageIds.length > _maxProcessedMessages) {
      final oldest = _processedMessageIds.first;
      _processedMessageIds.remove(oldest);
      Logger.debug('RoutingManager: Removed oldest processed message from cache');
    }
  }

  /// Check if a message is destined for this device
  bool _isForThisDevice(MessageModel message) {
    return message.finalReceiverId == _myDeviceId;
  }

  /// Check if a message should be forwarded to neighbors
  /// 
  /// Returns true if:
  /// - Message is not for this device
  /// - Hop count is below max hops (TTL not exceeded)
  bool _shouldForwardMessage(MessageModel message) {
    // Don't forward if message is for us
    if (_isForThisDevice(message)) {
      return false;
    }

    // Don't forward if hop count exceeded
    if (message.hopCount >= message.maxHops) {
      Logger.warning('RoutingManager: Message ${message.messageId} exceeded hop limit');
      return false;
    }

    // Message can be forwarded
    return true;
  }

  /// Deliver a message to the local application (ChatProvider, etc.)
  void _deliverLocally(MessageModel message) {
    Logger.info('RoutingManager: Delivering message ${message.messageId} to local application');
    _localMessageController.add(message);
  }

  /// Forward a message to all neighbors (except the sender)
  /// 
  /// STUB IMPLEMENTATION - Forwarding is currently DISABLED
  /// 
  /// When ready to enable multi-hop:
  /// 1. Get list of neighbors from TransportManager
  /// 2. Increment hopCount
  /// 3. Serialize message to bytes
  /// 4. Send to all neighbors except the one we received from
  /// 5. Use controlled flooding (broadcast to all neighbors)
  Future<void> _forwardToNeighbors(MessageModel message) async {
    // STUB: Forwarding disabled for FYP stability
    Logger.debug('RoutingManager: Forwarding is currently disabled (stub method)');
    
    // Future implementation:
    // 1. Increment hop count
    // final forwardedMessage = message.copyWith(hopCount: message.hopCount + 1);
    // 
    // 2. Get neighbors from TransportManager
    // final neighbors = _transportManager.getNeighbors();
    // 
    // 3. Serialize message
    // final messageBytes = _serializeMessage(forwardedMessage);
    // 
    // 4. Broadcast to all neighbors
    // await _transportManager.broadcastToAllPeers(messageBytes);
    //
    // 5. Log forwarding action
    // Logger.info('RoutingManager: Forwarded message ${message.messageId} to ${neighbors.length} neighbors');
  }

  /// Clear the processed message cache
  /// Useful for testing or resetting state
  void clearProcessedMessages() {
    _processedMessageIds.clear();
    Logger.info('RoutingManager: Cleared processed message cache');
  }

  /// Get statistics about the routing manager
  Map<String, dynamic> getStatistics() {
    return {
      'processedMessages': _processedMessageIds.length,
      'maxProcessedMessages': _maxProcessedMessages,
      'myDeviceId': _myDeviceId,
    };
  }

  /// Dispose resources
  void dispose() {
    _localMessageController.close();
    _processedMessageIds.clear();
  }
}
