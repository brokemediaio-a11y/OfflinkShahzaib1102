import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/app_colors.dart';
import '../../services/registration_service.dart';
import '../../services/storage/device_storage.dart';
import '../../utils/logger.dart';
import '../../utils/permissions_helper.dart';
import '../auth/permissions_screen.dart';

/// Screen for capturing username on first app launch
class UsernameRegistrationScreen extends StatefulWidget {
  const UsernameRegistrationScreen({super.key, this.initialUsername});

  final String? initialUsername;

  @override
  State<UsernameRegistrationScreen> createState() => _UsernameRegistrationScreenState();
}

class _UsernameRegistrationScreenState extends State<UsernameRegistrationScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _usernameController.text = widget.initialUsername ??
        DeviceStorage.getUsername() ??
        DeviceStorage.getDisplayName() ??
        '';
  }

  @override
  void dispose() {
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _saveUsername() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final username = _usernameController.text.trim();

      await RegistrationService.createAccount(username: username);

      Logger.info('User registered with username: $username');
      
      // Check if permissions are already granted
      final allPermissionsGranted = await PermissionsHelper.areAllPermissionsGranted();
      
      // Navigate to permissions screen if needed
      if (mounted) {
        if (allPermissionsGranted) {
          // Permissions already granted, can go directly to home
          // But we'll still show permissions screen for consistency
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const PermissionsScreen()),
          );
        } else {
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const PermissionsScreen()),
          );
        }
      }
    } on RegistrationException catch (e) {
      Logger.error('Error creating Firebase-backed account', e);
      setState(() {
        _errorMessage = e.message;
        _isLoading = false;
      });
    } catch (e) {
      Logger.error('Error saving username', e);
      setState(() {
        _errorMessage = 'Failed to save username. Please try again.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 32),
                // App Logo/Icon
                Icon(
                  Icons.person_add_rounded,
                  size: 80,
                  color: AppColors.primary,
                ),
                const SizedBox(height: 32),
                
                // Title
                Text(
                  'Welcome to OffLink',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                
                // Subtitle
                Text(
                  'Choose a username to get started',
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 48),
                
                // Username Input
                TextFormField(
                  controller: _usernameController,
                  enabled: !_isLoading,
                  maxLength: 20,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(20),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Username',
                    hintText: 'Enter your username',
                    prefixIcon: Icon(Icons.person, color: AppColors.primary),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppColors.primary, width: 2),
                    ),
                    filled: true,
                    fillColor: AppColors.surface,
                  ),
                  style: TextStyle(
                    fontSize: 16,
                    color: AppColors.textPrimary,
                  ),
                  validator: (value) {
                    if (value == null) {
                      return 'Please enter a username';
                    }
                    return RegistrationService.validateUsername(value);
                  },
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _saveUsername(),
                ),
                const SizedBox(height: 16),
                
                // Error Message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: Colors.red.shade700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (_errorMessage != null) const SizedBox(height: 16),
                
                // Continue Button
                ElevatedButton(
                  onPressed: _isLoading ? null : _saveUsername,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : const Text(
                          'Continue',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
                const SizedBox(height: 24),
                
                // Info Text
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: AppColors.primary, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Wi-Fi is required for first-time account creation. '
                          'This username will be reserved globally and also shown to nearby OffLink devices.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
