import 'package:flutter/material.dart';
import 'package:logging/logging.dart'; // Still needed for global logging setup
import 'package:shared_preferences/shared_preferences.dart'; // Direct import for MyApp's theme persistence
import 'package:msa/home_page.dart'; // NEW: Import your ServerHomePage

void main() {
  // Ensure Flutter binding is initialized before accessing plugins like SharedPreferences
  // This is crucial if SharedPreferences.getInstance() is called directly in main or MyApp's initState.
  WidgetsFlutterBinding.ensureInitialized();

  // Set up logging for Shelf to capture its output and print to console
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // Print to console for detailed debugging
    print('${record.level.name}: ${record.time}: ${record.message}');
  });
  runApp(const MyApp());
}

// MyApp is now a StatefulWidget to manage the themeMode for the MaterialApp
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.system; // Default to system theme preference

  @override
  void initState() {
    super.initState();
    _loadThemePreference(); // Load theme preference when the app starts
  }

  // Loads the saved theme preference from SharedPreferences
  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    // Default to false (light mode) if no preference is saved
    final isDarkMode = prefs.getBool('isDarkMode') ?? false;
    setState(() {
      _themeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;
    });
  }

  // Helper to save theme preference directly from MyApp
  Future<void> _saveThemePreference(bool isDarkMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isDarkMode', isDarkMode);
  }

  // Callback method to update the themeMode from child widgets (ServerHomePage)
  void toggleTheme(bool isDarkMode) {
    setState(() {
      _themeMode = isDarkMode ? ThemeMode.dark : ThemeMode.light;
    });
    // Save the preference immediately when toggled
    _saveThemePreference(isDarkMode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Minimal Server App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Inter',
        brightness: Brightness.light, // Explicitly define light theme brightness
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.blue, // Light mode AppBar background
          foregroundColor: Colors.white, // Light mode AppBar text/icon color
        ),
        // Default text styles for light theme
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.black87),
          bodySmall: TextStyle(color: Colors.black54),
          titleMedium: TextStyle(color: Colors.black),
          headlineSmall: TextStyle(color: Colors.black),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.grey[100], // Light mode input fill
          labelStyle: const TextStyle(color: Colors.black87),
          hintStyle: TextStyle(color: Colors.grey[600]),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: BorderSide(color: Colors.grey[300]!),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: const BorderSide(color: Colors.blue, width: 2.0),
          ),
        ),
        cardColor: Colors.white, // Light mode card background
        dialogTheme: const DialogThemeData(
          backgroundColor: Colors.white,
          titleTextStyle: TextStyle(color: Colors.black, fontSize: 20),
          contentTextStyle: TextStyle(color: Colors.black87),
        ),
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.indigo, // Darker primary color for dark mode
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Inter',
        brightness: Brightness.dark, // Explicitly define dark theme brightness
        scaffoldBackgroundColor: Colors.grey[900], // Dark background
        cardColor: Colors.grey[800], // Dark card backgrounds
        dialogTheme: DialogThemeData( // Adjust dialog theme for dark mode
          backgroundColor: Colors.grey[800],
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 20),
          contentTextStyle: TextStyle(color: Colors.white70),
        ),
        textTheme: const TextTheme( // Adjust text colors for dark mode
          bodyMedium: TextStyle(color: Colors.white),
          bodySmall: TextStyle(color: Colors.white70),
          titleMedium: TextStyle(color: Colors.white),
          headlineSmall: TextStyle(color: Colors.white),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.indigo[800], // Dark mode AppBar background
          foregroundColor: Colors.white, // Dark mode AppBar text/icon color
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.grey[700], // Dark mode input fill
          labelStyle: const TextStyle(color: Colors.white70),
          hintStyle: TextStyle(color: Colors.grey[400]),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: BorderSide(color: Colors.grey[600]!),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: Colors.blue[300] != null ? BorderSide(color: Colors.blue[300]!) : const BorderSide(color: Colors.blue),
          ),
        ),
      ),
      themeMode: _themeMode, // Use the themeMode state to apply the theme
      // Pass the toggleTheme method and current theme mode to ServerHomePage
      home: ServerHomePage(toggleTheme: toggleTheme, initialThemeMode: _themeMode),
    );
  }
}
