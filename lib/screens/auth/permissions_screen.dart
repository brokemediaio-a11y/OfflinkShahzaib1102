import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/app_colors.dart';
import '../../core/app_strings.dart';
import '../../core/constants.dart';
import '../../providers/device_provider.dart';
import '../../utils/permissions_helper.dart';
import '../../utils/logger.dart';
import '../home/home_screen.dart';

class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  Map<String, bool> _permissions = {
    'bluetooth': false,
    'location': false,
    'nearbyDevices': false,
  };

  bool _isLoading = false;
  bool _isNearbyDevicesSupported = false;

  @override
  void initState() {
    super.initState();
    _initializePermissions();
  }

  Future<void> _initializePermissions() async {
    // First check if Nearby Devices permission is supported
    await _checkNearbyDevicesSupport();
    // Then check all permissions
    await _checkPermissions();
  }

  Future<void> _checkNearbyDevicesSupport() async {
    final isSupported = await PermissionsHelper.isNearbyDevicesPermissionSupported();
    setState(() {
      _isNearbyDevicesSupported = isSupported;
      // If not supported, automatically mark as granted
      if (!isSupported) {
        _permissions['nearbyDevices'] = true;
      }
    });
  }

  Future<void> _checkPermissions() async {
    setState(() => _isLoading = true);
    final permissions = await PermissionsHelper.checkAllPermissions();
    setState(() {
      _permissions = permissions;
      // Ensure nearbyDevices is marked as granted if not supported on this device
      if (!_isNearbyDevicesSupported) {
        _permissions['nearbyDevices'] = true;
      }
      _isLoading = false;
    });
  }

  Future<void> _requestPermission(String permission) async {
    setState(() => _isLoading = true);
    bool granted = false;
    String? errorMessage;

    try {
      switch (permission) {
        case 'bluetooth':
          granted = await PermissionsHelper.requestBluetoothPermission();
          if (!granted) {
            errorMessage = 'Bluetooth permission is required. Please grant it in app settings.';
          }
          break;
        case 'location':
          granted = await PermissionsHelper.requestLocationPermission();
          if (!granted) {
            errorMessage = 'Location permission is required for Bluetooth scanning.';
          }
          break;
        case 'nearbyDevices':
          // Only request if supported on this device
          if (_isNearbyDevicesSupported) {
            granted = await PermissionsHelper.requestNearbyDevicesPermission();
            if (!granted) {
              errorMessage = 'Nearby devices permission is required.';
            }
          } else {
            // On older devices, this permission doesn't exist, so consider it granted
            granted = true;
          }
          break;
      }
    } catch (e) {
      errorMessage = 'Error requesting permission: ${e.toString()}';
      Logger.error('Error requesting $permission permission', e);
    }

    setState(() {
      _permissions[permission] = granted;
      _isLoading = false;
    });

    // After requesting any permission, refresh ALL permissions to update the UI.
    // Bluetooth and Nearby Devices permissions are separate on Android 12+ and must be requested independently.
    await _checkPermissions();

    // Show error message if permission was denied
    if (!granted && errorMessage != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: AppColors.error,
          action: SnackBarAction(
            label: 'Open Settings',
            textColor: AppColors.textLight,
            onPressed: () async {
              await openAppSettings();
            },
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  bool get _allPermissionsGranted {
    // Check only the permissions that are relevant for this device
    final bluetoothGranted = _permissions['bluetooth'] ?? false;
    final locationGranted = _permissions['location'] ?? false;
    final nearbyDevicesGranted = _isNearbyDevicesSupported 
        ? (_permissions['nearbyDevices'] ?? false)
        : true; // Not required on older devices
    
    return bluetoothGranted && locationGranted && nearbyDevicesGranted;
  }

  Future<void> _continue() async {
    if (!_allPermissionsGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please grant all permissions to continue'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final connectionManager = ref.read(connectionManagerProvider);
      await connectionManager.initialize();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.permissionsTitle),
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textLight,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),
                  // Description
                  Text(
                    AppStrings.permissionsDescription,
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Bluetooth Permission
                  _PermissionCard(
                    title: AppStrings.bluetoothPermission,
                    description: 'Required for device discovery and connection',
                    isGranted: _permissions['bluetooth'] ?? false,
                    onTap: () => _requestPermission('bluetooth'),
                    icon: Icons.bluetooth,
                  ),
                  const SizedBox(height: 16),
                  // Location Permission
                  _PermissionCard(
                    title: AppStrings.locationPermission,
                    description: 'Required for Bluetooth device scanning',
                    isGranted: _permissions['location'] ?? false,
                    onTap: () => _requestPermission('location'),
                    icon: Icons.location_on,
                  ),
                  // Nearby Devices Permission (only show on Android 12+)
                  if (_isNearbyDevicesSupported) ...[
                    const SizedBox(height: 16),
                    _PermissionCard(
                      title: AppStrings.nearbyDevicesPermission,
                      description: 'Required for discovering nearby devices',
                      isGranted: _permissions['nearbyDevices'] ?? false,
                      onTap: () => _requestPermission('nearbyDevices'),
                      icon: Icons.devices,
                    ),
                  ],
                  const SizedBox(height: 24),
                  // Continue Button
                  ElevatedButton(
                    onPressed: _isLoading ? null : _continue,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.textLight,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppConstants.defaultBorderRadius),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(AppColors.textLight),
                            ),
                          )
                        : const Text(
                            AppStrings.continueButton,
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final String title;
  final String description;
  final bool isGranted;
  final VoidCallback onTap;
  final IconData icon;

  const _PermissionCard({
    required this.title,
    required this.description,
    required this.isGranted,
    required this.onTap,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppConstants.defaultBorderRadius),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: isGranted
                      ? AppColors.success.withOpacity(0.1)
                      : AppColors.primary.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: isGranted ? AppColors.success : AppColors.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isGranted ? AppColors.success : AppColors.error,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  isGranted
                      ? AppStrings.permissionGranted
                      : AppStrings.permissionDenied,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textLight,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

