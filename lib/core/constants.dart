class AppConstants {
  // App Info
  static const String appName = 'OFFLINK';
  static const String appVersion = '1.0.0';
  
  // BLE Configuration
  static const String bleServiceUuid = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String bleCharacteristicUuid = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';
  static const Duration bleScanTimeout = Duration(seconds: 10);
  static const Duration connectionTimeout = Duration(seconds: 30);
  
  // Wi-Fi Direct Configuration
  /// TCP port used by WifiDirectManager for bidirectional chat communication.
  /// Must match WifiDirectManager.TCP_PORT in Kotlin.
  static const int wifiDirectTcpPort = 8988;

  /// Fixed Group Owner IP assigned by Android Wi-Fi Direct stack.
  static const String wifiDirectGroupOwnerIp = '192.168.49.1';

  // Message Configuration
  static const int maxMessageLength = 1000;
  static const int maxFileSize = 10 * 1024 * 1024; // 10MB
  
  // Storage Keys
  static const String messagesBoxName = 'messages';
  static const String deviceBoxName = 'devices';
  
  // UI Constants
  static const double defaultPadding = 16.0;
  static const double defaultBorderRadius = 12.0;
  static const Duration animationDuration = Duration(milliseconds: 300);
}




