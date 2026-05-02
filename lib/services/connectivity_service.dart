import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService {
  static Future<List<ConnectivityResult>> getCurrentConnectivity() async {
    return Connectivity().checkConnectivity();
  }

  static Future<bool> hasWifiConnection() async {
    final statuses = await getCurrentConnectivity();
    return statuses.contains(ConnectivityResult.wifi) ||
        statuses.contains(ConnectivityResult.ethernet);
  }

  static Future<bool> hasAnyNetworkConnection() async {
    final statuses = await getCurrentConnectivity();
    return !statuses.contains(ConnectivityResult.none);
  }
}
