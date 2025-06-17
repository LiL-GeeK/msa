import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart'; // For ScaffoldMessenger, SnackBar, openAppSettings

// A service class to handle all permission requests
class PermissionService {
  final Function(String) _addLog; // Callback for logging to the UI

  PermissionService(this._addLog);

  /// Requests necessary storage permissions based on the platform.
  /// Returns true if permission is granted, false otherwise.
  Future<bool> requestStoragePermission(BuildContext context) async {
    if (Platform.isAndroid) {
      _addLog('Checking Android storage permissions...');
      if (await Permission.manageExternalStorage.isGranted) {
        _addLog('MANAGE_EXTERNAL_STORAGE permission already granted.');
        return true;
      } else {
        _addLog('Requesting MANAGE_EXTERNAL_STORAGE permission...');
        PermissionStatus status = await Permission.manageExternalStorage.request();
        if (status.isGranted) {
          _addLog('MANAGE_EXTERNAL_STORAGE permission granted.');
          return true;
        } else if (status.isPermanentlyDenied) {
          _addLog('MANAGE_EXTERNAL_STORAGE permission permanently denied. Opening app settings.');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('All files access permission permanently denied. Please enable it in app settings.'),
              action: SnackBarAction(
                label: 'Settings',
                onPressed: () {
                  openAppSettings();
                },
              ),
              duration: const Duration(seconds: 8),
            ),
          );
          return false;
        } else {
          _addLog('MANAGE_EXTERNAL_STORAGE permission denied.');
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('All files access permission denied. Cannot choose folder.'),
              duration: Duration(seconds: 5),
            ),
          );
          return false;
        }
      }
    } else if (Platform.isIOS) {
      _addLog('Checking iOS storage permissions...');
      PermissionStatus status = await Permission.storage.status;
      if (!status.isGranted) {
        _addLog('Requesting storage permission...');
        status = await Permission.storage.request();
      }

      if (status.isGranted) {
        _addLog('Storage permission granted.');
        return true;
      } else if (status.isPermanentlyDenied) {
        _addLog('Storage permission permanently denied. Opening app settings.');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Storage permission permanently denied. Please enable it in app settings.'),
            action: SnackBarAction(
              label: 'Settings',
              onPressed: () {
                openAppSettings();
              },
            ),
            duration: const Duration(seconds: 8),
          ),
        );
        return false;
      } else {
        _addLog('Storage permission denied.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Storage permission denied. Cannot choose folder.'),
            duration: Duration(seconds: 5),
          ),
        );
        return false;
      }
    }
    // For other platforms (Windows, Linux, macOS), file_picker handles permissions directly
    // or they are not needed by the OS for user-selected files.
    _addLog('Storage permission not explicitly handled for this platform, assuming auto-handled or not required.');
    return true; // Assume true for other platforms for simplicity
  }
}