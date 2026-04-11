import '../models/known_contact_model.dart';
import '../utils/logger.dart';

/// Stub for Firebase-based contact lookup.
///
/// This service will allow users to add contacts by UID or username via
/// Firebase, enabling out-of-range contact addition. When messages are sent
/// to a Firebase-added contact who is out of BLE/WiFi range, the DTN queue
/// buffers the message until either:
///   1. The contact comes into mesh range, or
///   2. Internet becomes available and the message is uploaded via Firebase.
///
/// // TODO(offlink): Implement Firebase integration when backend is ready.
/// Required steps:
///   1. Add firebase_core and cloud_firestore dependencies
///   2. Create Firestore collection 'users' with fields: uid, username, displayName, avatarHash
///   3. Implement lookupByUsername() to query Firestore
///   4. Implement lookupByUid() to fetch user document directly
///   5. Wire up to ContactBookScreen's "Add by Username" flow
///   6. Add cross-internet message relay via Firebase Cloud Messaging
class FirebaseContactService {
  // TODO(offlink): Replace with actual Firebase initialization
  static bool _initialized = false;

  /// Initialize Firebase connection.
  /// No-op until Firebase is integrated.
  static Future<void> init() async {
    // TODO(offlink): Initialize Firebase app and Firestore instance
    _initialized = false;
    Logger.info('FirebaseContactService: stub initialized (Firebase not yet connected)');
  }

  /// Whether Firebase is available for contact lookup.
  static bool get isAvailable => _initialized;

  /// Look up a user by their username.
  ///
  /// Returns a [KnownContact] if found, null otherwise.
  /// // TODO(offlink): Implement Firestore query
  static Future<KnownContact?> lookupByUsername(String username) async {
    // TODO(offlink): Query Firestore 'users' collection where username == username
    Logger.warning(
        'FirebaseContactService: lookupByUsername("$username") called '
        'but Firebase is not yet implemented');
    return null;
  }

  /// Look up a user by their UID.
  ///
  /// Returns a [KnownContact] if found, null otherwise.
  /// // TODO(offlink): Implement Firestore document fetch
  static Future<KnownContact?> lookupByUid(String uid) async {
    // TODO(offlink): Fetch Firestore document 'users/$uid'
    Logger.warning(
        'FirebaseContactService: lookupByUid("$uid") called '
        'but Firebase is not yet implemented');
    return null;
  }

  /// Upload a pending message to Firebase for cross-internet delivery.
  ///
  /// // TODO(offlink): Implement when Firebase Cloud Messaging is set up.
  static Future<bool> uploadPendingMessage({
    required String toUserId,
    required String messagePayload,
  }) async {
    // TODO(offlink): Store in Firestore 'pending_messages' collection
    // and send FCM notification to target user
    Logger.warning(
        'FirebaseContactService: uploadPendingMessage called '
        'but Firebase is not yet implemented');
    return false;
  }
}
