import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are only configured for Android in this project.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAfIhEP2MkfHyniU_IuRKprQFsLBt217F4',
    appId: '1:37947810543:android:8f42438f731bc4d5b1711a',
    messagingSenderId: '37947810543',
    projectId: 'offlink-8a3a3',
    storageBucket: 'offlink-8a3a3.firebasestorage.app',
  );
}
