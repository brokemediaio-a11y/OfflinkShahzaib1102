import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../firebase_options.dart';
import '../utils/logger.dart';

class FirebaseBootstrapService {
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;

    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      _initialized = true;
      Logger.info('FirebaseBootstrapService: Firebase initialized');
    } catch (e, st) {
      Logger.error('FirebaseBootstrapService: failed to initialize Firebase', e, st);
      rethrow;
    }
  }

  static bool get isInitialized => _initialized;

  static FirebaseAuth get auth => FirebaseAuth.instance;
  static FirebaseFirestore get firestore => FirebaseFirestore.instance;

  static Future<User> ensureSignedInAnonymously() async {
    await init();

    final current = auth.currentUser;
    if (current != null) {
      return current;
    }

    final credential = await auth.signInAnonymously();
    final user = credential.user;
    if (user == null) {
      throw StateError('Anonymous sign-in completed without a Firebase user');
    }
    Logger.info('FirebaseBootstrapService: signed in anonymously');
    return user;
  }
}
