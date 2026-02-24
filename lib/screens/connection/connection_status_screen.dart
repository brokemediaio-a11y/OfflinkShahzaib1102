import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_colors.dart';
import '../../core/app_strings.dart';
import '../../core/constants.dart';
import '../../providers/connection_provider.dart';
import '../../services/communication/connection_manager.dart';
import '../home/home_screen.dart';

class ConnectionStatusScreen extends ConsumerWidget {
  const ConnectionStatusScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionState = ref.watch(connectionProvider);
    final connectionNotifier = ref.read(connectionProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.connectionStatus),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
      ),
      body: connectionState.connectedDevice == null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bluetooth_disabled,
                    size: 64,
                    color: AppColors.textSecondary.withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    AppStrings.disconnected,
                    style: TextStyle(
                      fontSize: 18,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const HomeScreen()),
                      );
                    },
                    child: const Text('Go to Home'),
                  ),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(AppConstants.defaultPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  // Connection Status Card
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppConstants.defaultBorderRadius),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          // Status Indicator
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: connectionState.state ==
                                      ConnectionStateType.connected
                                  ? AppColors.connected.withOpacity(0.1)
                                  : AppColors.disconnected.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              connectionState.state == ConnectionStateType.connected
                                  ? Icons.check_circle
                                  : Icons.error,
                              size: 40,
                              color: connectionState.state ==
                                      ConnectionStateType.connected
                                  ? AppColors.connected
                                  : AppColors.disconnected,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            connectionState.state == ConnectionStateType.connected
                                ? AppStrings.connected
                                : AppStrings.disconnected,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Device Information
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppConstants.defaultBorderRadius),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            AppStrings.deviceName,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            connectionState.connectedDevice?.name ?? 'Unknown',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            AppStrings.deviceAddress,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            connectionState.connectedDevice?.address ?? 'Unknown',
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            AppStrings.connectionType,
                            style: TextStyle(
                              fontSize: 14,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            connectionState.connectionType ==
                                    ConnectionType.wifiDirect
                                ? 'Wi-Fi Direct'
                                : 'None',
                            style: const TextStyle(
                              fontSize: 14,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Disconnect Button
                  ElevatedButton(
                    onPressed: () async {
                      await connectionNotifier.disconnect();
                      if (context.mounted) {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const HomeScreen()),
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.error,
                      foregroundColor: AppColors.textLight,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppConstants.defaultBorderRadius),
                      ),
                    ),
                    child: const Text(
                      AppStrings.disconnect,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
    );
  }
}

