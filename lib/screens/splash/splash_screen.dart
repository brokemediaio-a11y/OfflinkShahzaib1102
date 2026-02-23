import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/app_colors.dart';
import '../../core/app_strings.dart';
import '../../providers/device_provider.dart';
import '../../services/storage/device_storage.dart';
import '../../utils/permissions_helper.dart';
import '../../utils/logger.dart';
import '../auth/username_registration_screen.dart';
import '../auth/permissions_screen.dart';
import '../home/home_screen.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Wait a bit for splash screen to be visible
    await Future.delayed(const Duration(seconds: 2));

    // Check if user has completed registration (username setup)
    final isRegistrationComplete = DeviceStorage.isRegistrationComplete();
    Logger.info('Registration complete: $isRegistrationComplete');

    if (!mounted) return;

    if (!isRegistrationComplete) {
      // First time launch - go to username registration
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const UsernameRegistrationScreen()),
      );
      return;
    }

    // Check permissions before initializing communication stack
    final allPermissionsGranted = await PermissionsHelper.areAllPermissionsGranted();

    if (!mounted) return;

    if (!allPermissionsGranted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PermissionsScreen()),
      );
      return;
    }

    // Initialize connection manager once permissions are granted
    final connectionManager = ref.read(connectionManagerProvider);
    await connectionManager.initialize();

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primary,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // App Logo/Icon
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.bluetooth_connected,
                size: 64,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 32),
            // App Name
            const Text(
              AppStrings.appName,
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: AppColors.textLight,
              ),
            ),
            const SizedBox(height: 8),
            // Tagline
            Text(
              AppStrings.appTagline,
              style: TextStyle(
                fontSize: 16,
                color: AppColors.textLight.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 48),
            // Loading indicator
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.textLight),
            ),
            const SizedBox(height: 16),
            Text(
              AppStrings.loading,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.textLight.withOpacity(0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

