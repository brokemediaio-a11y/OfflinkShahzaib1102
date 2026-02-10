import 'package:flutter/material.dart';
import '../../core/app_colors.dart';
import '../../services/storage/device_storage.dart';
import '../../utils/logger.dart';

class EditNameDialog extends StatefulWidget {
  const EditNameDialog({super.key});

  @override
  State<EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<EditNameDialog> {
  late TextEditingController _nameController;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    final currentName = DeviceStorage.getDisplayName() ?? '';
    _nameController = TextEditingController(text: currentName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    
    if (name.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a name'),
            backgroundColor: AppColors.error,
          ),
        );
      }
      return;
    }

    if (name.length > 20) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Name must be 20 characters or less'),
            backgroundColor: AppColors.error,
          ),
        );
      }
      return;
    }

    setState(() => _isLoading = true);

    try {
      await DeviceStorage.setDisplayName(name);
      
      if (mounted) {
        Navigator.of(context).pop(true); // Return true to indicate name was saved
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Name updated to: $name'),
            backgroundColor: AppColors.primary,
          ),
        );
      }
    } catch (e) {
      Logger.error('Error saving name', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save name'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Device Name'),
      content: TextField(
        controller: _nameController,
        decoration: const InputDecoration(
          labelText: 'Device Name',
          hintText: 'Enter your name (max 20 chars)',
          border: OutlineInputBorder(),
        ),
        maxLength: 20,
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _saveName,
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}





