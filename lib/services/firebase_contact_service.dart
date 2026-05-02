import '../models/known_contact_model.dart';
import '../utils/logger.dart';
import 'connectivity_service.dart';
import 'firebase_bootstrap_service.dart';
import 'storage/device_storage.dart';

class FirebaseContactService {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    await FirebaseBootstrapService.init();
    _initialized = true;
    Logger.info('FirebaseContactService: initialized');
  }

  static bool get isAvailable => _initialized;

  static Future<KnownContact?> lookupByUsername(String username) async {
    await init();

    if (!await ConnectivityService.hasAnyNetworkConnection()) {
      throw StateError('Internet is required to add contacts by username.');
    }

    final normalized = username.trim().toLowerCase();
    if (normalized.isEmpty) {
      return null;
    }

    final firestore = FirebaseBootstrapService.firestore;
    final usernameDoc =
        await firestore.collection('usernames').doc(normalized).get();
    if (!usernameDoc.exists) {
      return null;
    }

    final uid = usernameDoc.data()?['uid'] as String?;
    if (uid == null || uid.isEmpty) {
      return null;
    }

    return lookupByUid(uid);
  }

  static Future<KnownContact?> lookupByUid(String uid) async {
    await init();

    final firestore = FirebaseBootstrapService.firestore;
    final userDoc = await firestore.collection('users').doc(uid).get();
    if (!userDoc.exists) {
      return null;
    }

    final data = userDoc.data();
    if (data == null) {
      return null;
    }

    final deviceUuid = data['deviceUuid'] as String?;
    if (deviceUuid == null || deviceUuid.isEmpty) {
      return null;
    }

    final myDeviceUuid = DeviceStorage.getDeviceId();
    if (deviceUuid == myDeviceUuid) {
      throw StateError('You cannot add yourself as a contact.');
    }

    final displayName =
        (data['displayName'] as String?) ??
        (data['username'] as String?) ??
        'Offlink User';

    return KnownContact(
      peerId: deviceUuid,
      displayName: displayName,
      deviceAddress: null,
      lastSeen: DateTime.now(),
      addedVia: 'firebase',
    );
  }

  static Future<bool> uploadPendingMessage({
    required String toUserId,
    required String messagePayload,
  }) async {
    Logger.warning(
      'FirebaseContactService: uploadPendingMessage is not implemented yet '
      '(toUserId=$toUserId, payloadLength=${messagePayload.length})',
    );
    return false;
  }
}
