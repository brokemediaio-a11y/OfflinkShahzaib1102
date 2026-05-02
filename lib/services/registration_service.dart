import 'package:cloud_firestore/cloud_firestore.dart';

import 'connectivity_service.dart';
import 'firebase_bootstrap_service.dart';
import 'storage/device_storage.dart';
import '../utils/logger.dart';

class RegistrationException implements Exception {
  final String message;

  RegistrationException(this.message);

  @override
  String toString() => message;
}

class RegistrationService {
  static final RegExp _usernamePattern = RegExp(r'^[a-zA-Z0-9 _-]+$');

  static String normalizeUsername(String username) => username.trim().toLowerCase();

  static String? validateUsername(String username) {
    final value = username.trim();
    if (value.isEmpty) return 'Please enter a username';
    if (value.length < 3) return 'Username must be at least 3 characters';
    if (value.length > 20) return 'Username must be less than 20 characters';
    if (!_usernamePattern.hasMatch(value)) {
      return 'Username can only contain letters, numbers, spaces, and - _';
    }
    return null;
  }

  static Future<void> createAccount({
    required String username,
  }) async {
    final validationError = validateUsername(username);
    if (validationError != null) {
      throw RegistrationException(validationError);
    }

    final online = await ConnectivityService.hasAnyNetworkConnection();
    if (!online) {
      throw RegistrationException(
        'Internet is required for account creation. Connect to Wi‑Fi or mobile data and try again.',
      );
    }

    final displayName = username.trim();
    final usernameLower = normalizeUsername(displayName);

    try {
      final user = await FirebaseBootstrapService.ensureSignedInAnonymously();
      final firestore = FirebaseBootstrapService.firestore;
      final deviceUuid = DeviceStorage.getDeviceId();
      final userRef = firestore.collection('users').doc(user.uid);
      final usernameRef = firestore.collection('usernames').doc(usernameLower);

      await firestore.runTransaction((transaction) async {
        final usernameSnapshot = await transaction.get(usernameRef);
        if (usernameSnapshot.exists) {
          final existingUid = usernameSnapshot.data()?['uid'] as String?;
          if (existingUid != null && existingUid != user.uid) {
            throw RegistrationException('That username is already taken.');
          }
        }

        final now = FieldValue.serverTimestamp();
        transaction.set(
          usernameRef,
          {
            'uid': user.uid,
            'username': displayName,
            'usernameLower': usernameLower,
            'updatedAt': now,
          },
          SetOptions(merge: true),
        );

        transaction.set(
          userRef,
          {
            'uid': user.uid,
            'deviceUuid': deviceUuid,
            'username': displayName,
            'usernameLower': usernameLower,
            'displayName': displayName,
            'isActive': true,
            'updatedAt': now,
            'lastSeenAt': now,
            'createdAt': now,
          },
          SetOptions(merge: true),
        );
      });

      await DeviceStorage.setDisplayName(displayName);
      await DeviceStorage.setUsername(displayName);
      await DeviceStorage.setFirebaseUid(user.uid);
      await DeviceStorage.setFirebaseRegistrationSynced(true);
      await DeviceStorage.setRegistrationComplete(true);

      Logger.info(
        'RegistrationService: account created for "$displayName" '
        '(firebaseUid=${user.uid}, deviceUuid=$deviceUuid)',
      );
    } on FirebaseException catch (e, st) {
      Logger.error(
        'RegistrationService: Firebase error creating account '
        '[${e.code}] ${e.message}',
        e,
        st,
      );
      throw RegistrationException(_firestoreMessageForCode(e));
    } on RegistrationException {
      rethrow;
    } catch (e, st) {
      Logger.error('RegistrationService: unexpected error creating account', e, st);
      throw RegistrationException('Failed to create account. Please try again.');
    }
  }

  /// Maps common Firestore / Auth codes so users see actionable text instead of a generic failure.
  static String _firestoreMessageForCode(FirebaseException e) {
    switch (e.code) {
      case 'permission-denied':
        return 'Server rejected this action (permissions). Ask your developer to check '
            'Firestore security rules for anonymous users and users/usernames collections.';
      case 'unavailable':
      case 'deadline-exceeded':
      case 'resource-exhausted':
        return 'Firebase is temporarily unreachable. Check your connection and try again.';
      case 'failed-precondition':
        return 'Could not complete registration (conflict or precondition failed). Try another username.';
      case 'already-exists':
        return 'That username is already taken.';
      default:
        return 'Could not create your account (${e.code}). Check your internet or try again.';
    }
  }

  static Future<bool> needsRegistration() async {
    final isComplete = DeviceStorage.isRegistrationComplete();
    final firebaseUid = DeviceStorage.getFirebaseUid();
    final synced = DeviceStorage.isFirebaseRegistrationSynced();
    return !isComplete || firebaseUid == null || firebaseUid.isEmpty || !synced;
  }
}
