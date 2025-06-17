import 'package:shared_preferences/shared_preferences.dart';

// A service class to handle all SharedPreferences operations
class PreferenceService {
  late SharedPreferences _prefs;

  // Initializes SharedPreferences instance. Must be called before other methods.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // Gets a String preference, returns null if not found
  String? getString(String key) {
    return _prefs.getString(key);
  }

  // Sets a String preference. If value is null or empty, it removes the key.
  Future<void> setString(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
  }

  // Gets a boolean preference, returns defaultValue if not found
  bool getBool(String key, {bool defaultValue = false}) {
    return _prefs.getBool(key) ?? defaultValue;
  }

  // Sets a boolean preference
  Future<void> setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  // Clears all preferences (use with caution!)
  Future<void> clearAll() async {
    await _prefs.clear();
  }
}