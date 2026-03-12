import 'package:hive_flutter/hive_flutter.dart';
import '../../models/message_model.dart';
import '../../utils/logger.dart';

/// Stores messages that are awaiting delivery via store-and-forward routing.
///
/// A message is placed here when:
///   1. The original sender cannot reach the final receiver directly
///      (peer is offline — message queued with status `pending`)
///   2. A relay device received a message it cannot yet forward
///      (no path to finalReceiverId — stored until a route appears)
///
/// Messages are removed when:
///   1. Successfully sent directly to the final receiver
///   2. A delivery ACK is received confirming the message arrived
///   3. The hop count exceeds maxHops (TTL expired)
class PendingMessageStorage {
  static const String _boxName = 'pending_messages';
  static Box<MessageModel>? _box;

  static Future<void> init() async {
    try {
      _box = await Hive.openBox<MessageModel>(_boxName);
      Logger.info(
          'PendingMessageStorage: initialized with ${_box!.length} pending messages');
    } catch (e) {
      Logger.error('PendingMessageStorage: failed to initialize', e);
      rethrow;
    }
  }

  // ── Save ─────────────────────────────────────────────────────────

  /// Store a message as pending (keyed by messageId for deduplication).
  static Future<void> savePendingMessage(MessageModel message) async {
    try {
      await _box?.put(message.messageId, message);
      Logger.info(
          'PendingMessageStorage: stored pending message '
          '${message.messageId} → ${message.finalReceiverId} '
          '(hop ${message.hopCount}/${message.maxHops})');
    } catch (e) {
      Logger.error(
          'PendingMessageStorage: error saving message ${message.messageId}', e);
    }
  }

  // ── Query ─────────────────────────────────────────────────────────

  /// Get all pending messages whose final destination is [finalReceiverId].
  static List<MessageModel> getPendingMessagesFor(String finalReceiverId) {
    return _box?.values
            .where((m) => m.finalReceiverId == finalReceiverId)
            .toList() ??
        [];
  }

  /// Get ALL pending messages (used when sending everything to a new relay).
  static List<MessageModel> getAllPendingMessages() {
    return _box?.values.toList() ?? [];
  }

  /// Check whether a message is currently queued.
  static bool isPending(String messageId) {
    return _box?.containsKey(messageId) ?? false;
  }

  // ── Remove ────────────────────────────────────────────────────────

  /// Remove a pending message after successful delivery or ACK receipt.
  static Future<void> removePendingMessage(String messageId) async {
    try {
      await _box?.delete(messageId);
      Logger.info(
          'PendingMessageStorage: removed pending message $messageId');
    } catch (e) {
      Logger.error(
          'PendingMessageStorage: error removing message $messageId', e);
    }
  }

  // ── Stats ─────────────────────────────────────────────────────────

  static int getPendingCount() => _box?.length ?? 0;

  static Future<void> clearAll() async {
    await _box?.clear();
    Logger.info('PendingMessageStorage: all pending messages cleared');
  }
}
