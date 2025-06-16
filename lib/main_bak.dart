import 'dart:async';
import 'dart:io'; // Required for HttpServer, Directory, Platform, FileSystemEntity
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Required for TextInputFormatter
import 'package:file_picker/file_picker.dart'; // Required for file picking
import 'package:shelf/shelf.dart'; // Required for Handler, Response
import 'package:shelf/shelf_io.dart' as shelf_io; // Required for serve
import 'package:shelf_static/shelf_static.dart'; // Required for createStaticHandler
import 'package:logging/logging.dart'; // Import for logging setup
import 'package:permission_handler/permission_handler.dart'; // Import for permission handler
import 'package:shelf_multipart/shelf_multipart.dart'; // For handling multipart form data
import 'package:share_plus/share_plus.dart'; // NEW: Import for sharing
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  // Set up logging for Shelf to capture its output and print to console
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    // Print to console for detailed debugging
    print('${record.level.name}: ${record.time}: ${record.message}');
  });
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Minimal Server App',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Inter', // Applying Inter font
      ),
      home: const ServerHomePage(),
    );
  }
}

class ServerHomePage extends StatefulWidget {
  const ServerHomePage({super.key});

  @override
  State<ServerHomePage> createState() => _ServerHomePageState();
}

class _ServerHomePageState extends State<ServerHomePage> {
  final TextEditingController _hostnameController = TextEditingController();
  final TextEditingController _portController = TextEditingController();
  HttpServer? _server;
  String _serverStatus = 'Server is stopped.';
  Color _statusColor = Colors.red;

  String? _selectedDirectoryPath;
  String? _serverIpAddress;

  String? _custom404FilePath; // NEW: Path to the custom 404 HTML file
  String? _custom404HtmlContent; // NEW: Content of the custom 404 HTML file

  double _bytesTransferredThisSecond = 0; // Tracks bytes for current second
  String _currentBandwidth = '0 KB/s'; // Display string for bandwidth
  bool _isActivityActive = false; // True if recent data transfer occurred
  Timer? _activityTimer; // Timer to reset _isActivityActive
  Timer? _bandwidthTimer; // Timer to update _currentBandwidth periodically

  late SharedPreferences _prefs; // Use late for initialization in initState

  // List to store log messages
  final List<String> _logMessages = [];
  final ScrollController _logScrollController = ScrollController(); // To auto-scroll logs

  // New: List to store file system entries for the explorer
  List<FileSystemEntity> _fileSystemEntries = [];
  final ScrollController _fileExplorerScrollController = ScrollController(); // For file explorer scrolling

  String? _getServerUrl() {
    if (_serverIpAddress != null && _portController.text.isNotEmpty) {
      return 'http://$_serverIpAddress:${_portController.text}/';
    }
    return null;
  }

  bool _isTextFile(String filePath) {
    final textExtensions = const [
      '.txt', '.log', '.csv', '.json', '.xml', '.yaml', '.yml',
      '.html', '.htm', '.css', '.js', '.ts', '.dart', '.java', '.py', '.c', '.cpp', '.h', '.hpp',
      '.md', '.sh', '.bat', '.ps1', '.sql', '.php', '.go', '.rb', '.rs', '.swift',
      '.toml', '.ini', '.cfg', '.conf', '.env', '.gitignore'
    ];
    final extension = filePath.toLowerCase().split('.').last;
    return textExtensions.contains('.$extension'); // Prepend '.' to match list format
  }

  @override
  void initState() {
    super.initState();
    _initPreferencesAndLoad(); // NEW: Call an async init method

    _hostnameController.addListener(() => _savePreference('hostname', _hostnameController.text));
    _portController.addListener(() => _savePreference('port', _portController.text));
  }

  @override
  void dispose() {
    _hostnameController.dispose();
    _portController.dispose();
    // NEW: Remove listeners to prevent memory leaks
    _hostnameController.removeListener(() => _savePreference('hostname', _hostnameController.text));
    _portController.removeListener(() => _savePreference('port', _portController.text));

    _stopServer();
    _logScrollController.dispose(); // Dispose the log scroll controller
    _fileExplorerScrollController.dispose(); // Dispose the file explorer scroll controller
    _activityTimer?.cancel();   // NEW: Cancel activity timer
    _bandwidthTimer?.cancel();  // NEW: Cancel bandwidth timer
    super.dispose();
  }

  // NEW: Initializes SharedPreferences and loads saved data
  Future<void> _initPreferencesAndLoad() async {
    _prefs = await SharedPreferences.getInstance();
    _loadSavedPreferences();
  }

  // NEW: Loads saved preferences from SharedPreferences
  Future<void> _loadSavedPreferences() async {
    _addLog('Loading saved preferences...');
    setState(() {
      _hostnameController.text = _prefs.getString('hostname') ?? '0.0.0.0';
      _portController.text = _prefs.getString('port') ?? '8080';
      _selectedDirectoryPath = _prefs.getString('selectedDirectoryPath');
      _custom404FilePath = _prefs.getString('custom404FilePath');
    });

    if (_selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty) {
      _addLog('Loaded saved folder: $_selectedDirectoryPath');
      _listFilesAndFolders(); // Populate file explorer if folder was saved
    }
    if (_custom404FilePath != null && _custom404FilePath!.isNotEmpty) {
      _addLog('Loaded saved 404 page: $_custom404FilePath');
      // Content will be read when server starts
    }
  }

  // NEW: Helper to save a single preference
  Future<void> _savePreference(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
    _addLog('Saved preference: $key = $value');
  }

  /// Adds a log message to the log display and scrolls to the bottom.
  void _addLog(String message) {
    setState(() {
      _logMessages.add('${DateTime.now().toIso8601String().substring(11, 19)} - $message');
      // Ensure we don't store too many logs to prevent memory issues
      if (_logMessages.length > 200) {
        _logMessages.removeAt(0); // Remove oldest log
      }
    });
    // Scroll to the bottom of the log list after adding a new message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _updateBandwidth(Timer timer) {
    setState(() {
      if (_bytesTransferredThisSecond > 0) {
        final speedKBps = _bytesTransferredThisSecond / 1024; // Convert to KB
        if (speedKBps >= 1024) {
          _currentBandwidth = '${(speedKBps / 1024).toStringAsFixed(2)} MB/s';
        } else {
          _currentBandwidth = '${speedKBps.toStringAsFixed(2)} KB/s';
        }
        _bytesTransferredThisSecond = 0; // Reset for the next second's calculation
      } else {
        _currentBandwidth = '0 KB/s';
      }
    });
  }

  Middleware _countingMiddleware() {
    return (innerHandler) {
      return (Request request) async {
        final response = await innerHandler(request);

        // Corrected: Access response body via read() directly.
        // A response always has a body stream, even if empty.
        final originalStream = response.read();
        final countingStream = originalStream.transform<List<int>>(
          StreamTransformer.fromHandlers(
            handleData: (List<int> data, EventSink<List<int>> sink) {
              // Update UI state for activity and byte count
              setState(() {
                _bytesTransferredThisSecond += data.length;
                _isActivityActive = true; // Indicate activity
                _activityTimer?.cancel(); // Reset activity timer if active
                _activityTimer = Timer(const Duration(milliseconds: 500), () {
                  // After a short delay, if no new data, set activity to false
                  setState(() {
                    _isActivityActive = false;
                  });
                });
              });
              sink.add(data); // Pass data through
            },
            handleError: (error, stackTrace, sink) {
              sink.addError(error, stackTrace);
            },
            handleDone: (sink) {
              sink.close();
            },
          ),
        );
        return response.change(body: countingStream); // Return response with counting stream
      };
    };
  }

  Future<void> _shareServerUrl() async {
    final url = _getServerUrl();
    if (url != null) {
      _addLog('Attempting to share server URL: $url');
      try {
        await Share.share(url, subject: 'My Flutter Server URL');
        _addLog('Server URL shared successfully.');
      } catch (e) {
        _addLog('Failed to share URL: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share URL: $e')),
        );
      }
    } else {
      _addLog('Cannot share URL: Server not running.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server is not running to share URL.')),
      );
    }
  }

  Future<void> _copyServerUrl() async {
    final url = _getServerUrl();
    if (url != null) {
      _addLog('Attempting to copy server URL to clipboard: $url');
      try {
        await Clipboard.setData(ClipboardData(text: url));
        _addLog('Server URL copied to clipboard.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Server URL copied to clipboard!')),
        );
      } catch (e) {
        _addLog('Failed to copy URL to clipboard: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to copy URL: $e')),
        );
      }
    } else {
      _addLog('Cannot copy URL: Server not running.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server is not running to copy URL.')),
      );
    }
  }

  /// Requests storage permissions (for Android, specifically).
  /// Returns true if permission is granted, false otherwise.
  Future<bool> _requestStoragePermission() async {
    if (Platform.isAndroid) {
      _addLog('Checking Android storage permissions...');
      // For Android 11 (API 30) and above, MANAGE_EXTERNAL_STORAGE is the way for broad access.
      // It leads to a system screen, not a simple dialog.
      if (await Permission.manageExternalStorage.isGranted) {
        _addLog('MANAGE_EXTERNAL_STORAGE permission already granted.');
        return true;
      } else {
        _addLog('Requesting MANAGE_EXTERNAL_STORAGE permission...');
        // Request the permission
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
                  openAppSettings(); // Direct user to app settings
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
    } else if (Platform.isIOS) { // || Platform.isMacOS) {
      // For iOS/macOS, file_picker itself might trigger necessary prompts.
      // Permission.storage can be used for general read/write.
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
                openAppSettings(); // Direct user to app settings
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
    // For other platforms (Linux, Windows), file_picker handles permissions or they are not needed.
    _addLog('Storage permission not applicable or not explicitly handled for this platform.');
    return true; // Assume true for other platforms for now
  }

  /// Opens a file picker to allow the user to select a directory.
  Future<void> _pickDirectory() async {
    // Request permission before picking directory
    bool granted = await _requestStoragePermission();
    if (!granted) {
      _addLog('Cannot pick directory: Storage permission not granted.');
      setState(() {
        _serverStatus = 'Error: Storage permission not granted.';
        _statusColor = Colors.red;
      });
      return;
    }

    try {
      String? result = await FilePicker.platform.getDirectoryPath();

      if (result != null) {
        setState(() {
          _selectedDirectoryPath = result;
          _addLog('Selected folder: $_selectedDirectoryPath');
        });
        _savePreference('selectedDirectoryPath', _selectedDirectoryPath); // NEW: Save selected directory
        _listFilesAndFolders(); // Refresh file list when a new folder is selected
      } else {
        _addLog('Folder selection cancelled.');
      }
    } catch (e) {
      _addLog('Error picking directory: $e');
      setState(() {
        _serverStatus = 'Error picking directory: $e';
        _statusColor = Colors.red;
      });
      print('Error picking directory: $e');
    }
  }

  /// Handles incoming file upload requests using shelf_multipart.
  Future<Response> _handleUploadRequest(Request request) async {
    if (request.method != 'POST') {
      _addLog('UPLOAD: Received non-POST request to /upload: ${request.method}');
      // Corrected: Use Response constructor for method not allowed
      return Response(HttpStatus.methodNotAllowed, body: 'Method Not Allowed');
    }

    if (_selectedDirectoryPath == null || _selectedDirectoryPath!.isEmpty) {
      _addLog('UPLOAD: No directory selected for upload.');
      return Response.badRequest(body: 'Error: No directory selected for file uploads.');
    }

    try {
      // Use request.parts to get the multipart fields
      if (request.multipart() case var multipart?) {
        await for (var part in multipart.parts) {
          if (request.formData() case var form?) {
            await for (final formData in form.formData) {
              if (formData.name == 'fileToUpload') { // 'fileToUpload' is the name attribute from the HTML input
                final bytes = await part.readBytes(); // Read bytes once
                final uploadFile = File(
                    '$_selectedDirectoryPath/${formData.name}');
                await part.readBytes().then((bytes) =>
                    uploadFile.writeAsBytes(bytes));
                setState(() {
                  _bytesTransferredThisSecond += bytes.length;
                  _isActivityActive = true; // Indicate activity for uploads
                  _activityTimer?.cancel();
                  _activityTimer = Timer(const Duration(milliseconds: 500), () {
                    setState(() { _isActivityActive = false; });
                  });
                });
                _addLog(
                    'UPLOAD: Successfully uploaded file: ${uploadFile.path}');
                _listFilesAndFolders(); // Refresh file list after successful upload
                return Response.ok(
                    'File uploaded successfully! File saved to: ${formData.name}');
                            }
            }
          }
        }
      }
      _addLog('UPLOAD: No file found with name "fileToUpload" in multipart request.');
      return Response.badRequest(body: 'No file found in the request (expected field "fileToUpload").');
    } catch (e, st) {
      _addLog('UPLOAD: Error processing upload: $e');
      print('Upload error: $e\n$st');
      return Response.internalServerError(body: 'Failed to upload file: $e');
    }
  }

  /// Provides a simple HTML form for file uploads.
  String _getUploadFormHtml() {
    return '''
<!DOCTYPE html>
<html>
<head>
    <title>File Upload</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { font-family: sans-serif; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 100vh; margin: 0; background-color: #f4f4f4; color: #333; }
        .container { background-color: #fff; padding: 25px; border-radius: 10px; box-shadow: 0 4px 8px rgba(0,0,0,0.1); max-width: 400px; width: 90%; text-align: center; }
        h1 { color: #333; margin-bottom: 20px; }
        form { display: flex; flex-direction: column; align-items: center; }
        input[type="file"] { margin-bottom: 15px; border: 1px solid #ddd; padding: 10px; border-radius: 5px; width: 100%; box-sizing: border-box; }
        input[type="submit"] { background-color: #007bff; color: white; padding: 12px 20px; border: none; border-radius: 5px; cursor: pointer; font-size: 16px; transition: background-color 0.3s ease; }
        input[type="submit"]:hover { background-color: #0056b3; }
        p { margin-top: 20px; font-size: 14px; color: #666; }
        a { color: #007bff; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Upload File to Server</h1>
        <form action="/upload" method="post" enctype="multipart/form-data">
            <input type="file" name="fileToUpload" id="fileToUpload" required>
            <input type="submit" value="Upload File">
        </form>
        <p>Ensure a folder is selected in the app for uploads to work.</p>
        <p><a href="/">Go Back to Root</a></p>
    </div>
</body>
</html>
    ''';
  }

  /// Lists files and folders in the selected directory for the file explorer.
  Future<void> _listFilesAndFolders() async {
    if (_selectedDirectoryPath == null || _selectedDirectoryPath!.isEmpty) {
      setState(() {
        _fileSystemEntries = [];
      });
      _addLog('No folder selected for file explorer. Clear file explorer.');
      return;
    }

    _addLog('Scanning directory for file explorer: $_selectedDirectoryPath');
    try {
      final directory = Directory(_selectedDirectoryPath!);
      if (!await directory.exists()) {
        _addLog('Error: Directory does not exist for listing: $_selectedDirectoryPath');
        setState(() {
          _fileSystemEntries = [];
        });
        return;
      }

      final contents = await directory.list().toList();
      // Sort to have directories first, then files, both alphabetically
      contents.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1; // Directory comes before file
        if (!aIsDir && bIsDir) return 1;  // File comes after directory
        return a.path.toLowerCase().compareTo(b.path.toLowerCase()); // Alphabetical
      });

      setState(() {
        _fileSystemEntries = contents;
      });
      _addLog('Found ${_fileSystemEntries.length} items in $_selectedDirectoryPath');
    } catch (e, st) {
      _addLog('Error listing directory contents for file explorer: $e');
      print('Error listing files: $e\n$st');
      setState(() {
        _fileSystemEntries = [];
      });
    }
  }


  /// Starts the HTTP server on the specified hostname and port.
  Future<void> _startServer() async {
    await _stopServer(); // Stop any existing server
    _logMessages.clear(); // Clear previous logs
    _addLog('Attempting to start server...');

    final String hostname = _hostnameController.text.trim();
    final int? port = int.tryParse(_portController.text.trim());

    if (hostname.isEmpty || port == null || port <= 0 || port > 65535) {
      _addLog('Invalid hostname or port provided.');
      setState(() {
        _serverStatus = 'Invalid hostname or port.';
        _statusColor = Colors.orange;
      });
      return;
    }

    try {
      _bandwidthTimer?.cancel(); // Cancel any existing timer
      _bandwidthTimer = Timer.periodic(const Duration(seconds: 1), _updateBandwidth);

      // Read 404 content before starting server (if selected)
      if (_custom404FilePath != null) {
        await _readCustom404Content(_custom404FilePath!);
      } else {
        _custom404HtmlContent = null; // Ensure it's null if no file chosen
      }

      Handler handler;
      if (_selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty) {
        final Directory staticFilesDirectory = Directory(_selectedDirectoryPath!);
        if (!await staticFilesDirectory.exists()) {
          _addLog('Error: Selected directory does not exist: $_selectedDirectoryPath');
          setState(() {
            _serverStatus = 'Error: Selected directory does not exist.';
            _statusColor = Colors.red;
          });
          return;
        }

        handler = Pipeline()
            .addMiddleware(logRequests())
            // .addMiddleware(multipartRuntime().middleware)
            .addMiddleware(_countingMiddleware())
            .addHandler(Cascade()
            .add((Request request) { // Handle specific routes before static files
          final path = request.url.pathSegments.join('/');
          if (path == 'upload' && request.method == 'POST') {
            _addLog('Routing POST request to _handleUploadRequest for /upload');
            return _handleUploadRequest(request);
          } else if (path == 'upload.html' && request.method == 'GET') {
            _addLog('Serving upload form for GET request to /upload.html');
            return Response.ok(_getUploadFormHtml(), headers: {'Content-Type': 'text/html'});
          }
          return Response.notFound(''); // Pass to next handler in cascade if not matched
        })
            .add(createStaticHandler(_selectedDirectoryPath!, defaultDocument: 'index.html')) // Serve static files
        // NEW: Add custom 404 handler AFTER static handler in the cascade
            .add((Request request) {
          _addLog('Custom 404 Handler: Path not found by previous handlers: ${request.url.path}');
          if (_custom404HtmlContent != null) {
            return Response(HttpStatus.notFound, headers: {'Content-Type': 'text/html'}, body: _custom404HtmlContent);
          }
          return Response.notFound('Not Found'); // Fallback to default plain text
        })
            .handler); // Get the combined handler

        setState(() {
          _serverStatus = 'Server running on http://$hostname:$port/' ' serving files from: $_selectedDirectoryPath';
          _statusColor = Colors.green;
        });
        _addLog('Server will serve files from: $_selectedDirectoryPath');
        _addLog('Upload form available at http://$hostname:$port/upload.html');
        _listFilesAndFolders();

      } else {
        // Handle server when no folder is selected
        handler = Pipeline()
            .addMiddleware(logRequests())
            // .addMiddleware(multipartRuntime().middleware)
            .addMiddleware(_countingMiddleware())
            .addHandler((Request request) {
          final path = request.url.pathSegments.join('/');
          _addLog('DEBUG: Custom handler received request for path: /$path');
          if (path == '') {
            _addLog('DEBUG: Serving default index page for /');
            return Response.ok('<html><body><h1>Hello from Flutter Server!</h1><p>You requested: /</p><p>No custom folder selected.</p></body></html>', headers: {'Content-Type': 'text/html'});
          } else if (path == 'api') {
            _addLog('DEBUG: Serving default API response for /api');
            return Response.ok('{"message": "This is an API response."}', headers: {'Content-Type': 'application/json'});
          } else if (path == 'upload.html' || path == 'upload') {
            _addLog('DEBUG: Serving upload form (no folder selected) for /$path');
            return Response.ok(_getUploadFormHtml(), headers: {'Content-Type': 'text/html'});
          }
          _addLog('DEBUG: Path not found by custom handler: /$path');
          // NEW: Use custom 404 if available, otherwise fallback
          if (_custom404HtmlContent != null) {
            return Response(HttpStatus.notFound, headers: {'Content-Type': 'text/html'}, body: _custom404HtmlContent);
          }
          return Response.notFound('Not Found'); // Fallback
        });

        setState(() {
          _serverStatus = 'Server running on http://$hostname:$port/ (No custom folder selected)';
          _statusColor = Colors.green;
        });
        _addLog('Server started with default content handler.');
        setState(() {
          _fileSystemEntries = [];
        });
      }

      _server = await shelf_io.serve(handler, hostname, port);
      final actualIp = _server!.address.host;

      setState(() {
        _serverIpAddress = actualIp;
        _serverStatus = 'Server running on http://$_serverIpAddress:$port/${_selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                ? ' serving files from: $_selectedDirectoryPath'
                : ' (No custom folder selected)'}';
        _statusColor = Colors.green;
      });

      _addLog('Server successfully started on http://$_serverIpAddress:$port/');
      // Re-trigger file listing if a directory is selected
      if (_selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty) {
        _listFilesAndFolders();
      } else {
        setState(() {
          _fileSystemEntries = [];
        });
      }
      _addLog('Upload form available at http://$_serverIpAddress:$port/upload.html');


    } on SocketException catch (e) {
      _addLog('Socket Error: ${e.message} (Is the address already in use?)');
      setState(() {
        _serverStatus = 'Error: ${e.message} (Is the address already in use?)';
        _statusColor = Colors.red;
        _serverIpAddress = null;
      });
      print('SocketException: $e');
    } catch (e) {
      _addLog('Failed to start server: $e');
      setState(() {
        _serverStatus = 'Failed to start server: $e';
        _statusColor = Colors.red;
        _serverIpAddress = null;
      });
      print('Error starting server: $e');
    }
  }

  /// Stops the currently running HTTP server.
  Future<void> _stopServer() async {
    if (_server != null) {
      _addLog('Attempting to stop server...');
      try {
        await _server!.close(force: true);
        setState(() {
          _serverStatus = 'Server stopped.';
          _statusColor = Colors.red;
          // _custom404FilePath = null; // NEW: Clear 404 path on stop
          // _custom404HtmlContent = null; // NEW: Clear 404 content on stop
        });
        _server = null;
        _addLog('Server successfully stopped.');
        setState(() {
          _fileSystemEntries = []; // Clear file explorer on server stop
        });
      } catch (e) {
        _addLog('Error stopping server: $e');
        setState(() {
          _serverStatus = 'Error stopping server: $e';
          _statusColor = Colors.red;
        });
        print('Error stopping server: $e');
      }
    }
  }

  Future<void> _pickCustom404File() async {
    // Permission for file picking is handled by _requestStoragePermission
    // which is called by _pickDirectory. For simplicity, we'll assume
    // that permission is generally handled when picking any file/folder.
    // If you explicitly want to request permission before picking JUST a 404 file
    // without picking a general directory first, you'd call _requestStoragePermission here.

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['html', 'htm'], // Only allow HTML files
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        _addLog('Selected custom 404 file: $filePath');
        await _readCustom404Content(filePath); // Read content immediately

        setState(() {
          _custom404FilePath = filePath;
        });
        _savePreference('custom404FilePath', _custom404FilePath); // NEW: Save custom 404 file path
      } else {
        _addLog('Custom 404 file selection cancelled.');
      }
    } catch (e) {
      _addLog('Error picking custom 404 file: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking 404 file: $e')),
      );
    }
  }

  // NEW: Function to read content of the custom 404 HTML file
  Future<void> _readCustom404Content(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        _custom404HtmlContent = await file.readAsString();
        _addLog('Successfully read custom 404 HTML content.');
      } else {
        _custom404HtmlContent = null;
        _addLog('Custom 404 HTML file does not exist: $filePath');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selected 404 HTML file does not exist.')),
        );
      }
    } catch (e) {
      _custom404HtmlContent = null;
      _addLog('Failed to read custom 404 HTML content: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to read 404 HTML content: $e')),
      );
    }
  }

  /// Views the content of a text-based file in a dialog.
  Future<void> _viewTextFile(File file) async {
    _addLog('Attempting to view file: ${file.path}');
    try {
      final content = await file.readAsString();
      _addLog('Successfully read content of ${file.path.split(Platform.pathSeparator).last}');

      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(file.path.split(Platform.pathSeparator).last), // Display file name as title
            content: SizedBox( // Constrain height for dialog content
              width: MediaQuery.of(context).size.width * 0.8, // 80% of screen width
              height: MediaQuery.of(context).size.height * 0.6, // 60% of screen height
              child: SingleChildScrollView(
                child: Text(
                  content,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12.0), // Monospace font for code/text
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                },
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    } catch (e, st) {
      _addLog('Error reading file for viewing: $e');
      print('File view error: $e\n$st');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to read file for viewing: ${file.path.split(Platform.pathSeparator).last}')),
      );
    }
  }

  Future<void> _downloadFile(File file) async {
    if (_serverIpAddress == null || _selectedDirectoryPath == null) {
      _addLog('Download failed: Server not running or no directory selected.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server not active or directory not selected.'), duration: Duration(seconds: 3)),
      );
      return;
    }

    // Construct the URL for the file. Need to remove the base path.
    // Example: /home/user/my_server_files/image.jpg -> image.jpg
    // Ensure relative path starts with / for URL, or strip leading separator if present
    final relativePath = file.path.substring(_selectedDirectoryPath!.length);
    final urlPath = relativePath.startsWith(Platform.pathSeparator)
        ? relativePath.substring(Platform.pathSeparator.length)
        : relativePath;

    final urlString = 'http://$_serverIpAddress:${_portController.text}/$urlPath';
    _addLog('Attempting to download: $urlString');

    final uri = Uri.parse(urlString);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication); // Use externalApplication for browser
      _addLog('Download link launched: $urlString');
    } else {
      _addLog('Could not launch download URL: $urlString');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open download link for ${file.path.split(Platform.pathSeparator).last}'), duration: Duration(seconds: 3)),
      );
    }
  }

  /// Deletes a file or an empty directory after user confirmation.
  /// (This method was previously added but might have been lost)
  Future<void> _deleteFileSystemEntry(FileSystemEntity entity) async {
    _addLog('Attempting to delete: ${entity.path}');

    // Show confirmation dialog
    bool confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Confirm Deletion'),
          content: Text('Are you sure you want to delete "${entity.path.split(Platform.pathSeparator).last}"?'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    ) ??
        false; // Default to false if dialog is dismissed

    if (!confirm) {
      _addLog('Deletion cancelled for: ${entity.path}');
      return;
    }

    try {
      if (entity is File) {
        await entity.delete();
        _addLog('Successfully deleted file: ${entity.path}');
      } else if (entity is Directory) {
        // Only delete empty directories, or ask for recursive delete
        if ((await entity.list().isEmpty)) { // Check if directory is empty
          await entity.delete();
          _addLog('Successfully deleted empty directory: ${entity.path}');
        } else {
          _addLog('Deletion failed: Directory is not empty. Cannot delete non-empty directories without recursive option.');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Cannot delete non-empty folder: ${entity.path.split(Platform.pathSeparator).last}'), duration: Duration(seconds: 4)),
          );
          return;
        }
      }
      _listFilesAndFolders(); // Refresh file list after deletion
    } catch (e, st) {
      _addLog('Error deleting ${entity.path}: $e');
      print('Deletion error: $e\n$st');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: ${entity.path.split(Platform.pathSeparator).last}'), duration: Duration(seconds: 4)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minimal Server App'),
        centerTitle: true,
      ),
      body: SingleChildScrollView( // WRAPPED THE MAIN COLUMN IN SingleChildScrollView
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Hostname input field
            TextField(
              controller: _hostnameController,
              decoration: InputDecoration(
                labelText: 'Hostname',
                hintText: 'e.g., 0.0.0.0 or 127.0.0.1',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                filled: true,
                fillColor: Colors.grey[100],
              ),
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 16.0),
            // Port input field
            TextField(
              controller: _portController,
              decoration: InputDecoration(
                labelText: 'Port',
                hintText: 'e.g., 8080',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                filled: true,
                fillColor: Colors.grey[100],
              ),
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              textInputAction: TextInputAction.done,
            ),
            const SizedBox(height: 24.0),
            // Choose Folder Button
            ElevatedButton.icon(
              onPressed: _server == null ? _pickDirectory : null, // Disable when server is running
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose Folder'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                elevation: 5,
              ),
            ),
            const SizedBox(height: 16.0),
            // Display selected folder path
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Colors.blueGrey[50],
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(color: Colors.blueGrey, width: 1.0),
              ),
              child: Text(
                _selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                    ? 'Selected Folder: $_selectedDirectoryPath'
                    : 'No folder selected. Serving default content.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.0,
                  color: _selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                      ? Colors.blueGrey[800]
                      : Colors.grey[600],
                  fontStyle: _selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                      ? FontStyle.normal
                      : FontStyle.italic,
                ),
              ),
            ),
            const SizedBox(height: 24.0),
            ElevatedButton.icon(
              onPressed: _server == null ? _pickCustom404File : null, // Disable when server is running
              icon: const Icon(Icons.error_outline),
              label: const Text('Choose 404 Page'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                elevation: 5,
              ),
            ),
            const SizedBox(height: 16.0),
            // NEW: Display selected 404 file path
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(color: Colors.orange, width: 1.0),
              ),
              child: Text(
                _custom404FilePath != null && _custom404FilePath!.isNotEmpty
                    ? 'Custom 404 Page: $_custom404FilePath'
                    : 'No custom 404 page selected. Default "Not Found" will be used.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.0,
                  color: _custom404FilePath != null && _custom404FilePath!.isNotEmpty
                      ? Colors.orange[800]
                      : Colors.grey[600],
                  fontStyle: _custom404FilePath != null && _custom404FilePath!.isNotEmpty
                      ? FontStyle.normal
                      : FontStyle.italic,
                ),
              ),
            ),
            const SizedBox(height: 24.0),
            // Start/Stop Server Button
            ElevatedButton(
              onPressed: _server == null ? _startServer : _stopServer,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8.0),
                ),
                backgroundColor: _server == null ? Colors.green : Colors.red,
                foregroundColor: Colors.white,
                elevation: 5,
              ),
              child: Text(
                _server == null ? 'Start Server' : 'Stop Server',
                style: const TextStyle(fontSize: 18.0, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 24.0),
            // Server Status Display
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: _statusColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(color: _statusColor, width: 1.5),
              ),
              child: Text(
                _serverStatus,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16.0,
                  color: _statusColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 16.0), // Smaller gap

            // NEW: Activity and Bandwidth Display
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(color: Colors.blue, width: 1.0),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isActivityActive ? Icons.wifi_protected_setup : Icons.wifi_off, // Icon for activity
                        color: _isActivityActive ? Colors.green : Colors.red,
                        size: 24.0,
                      ),
                      const SizedBox(width: 8.0),
                      Text(
                        _isActivityActive ? 'Active' : 'Idle',
                        style: TextStyle(
                          fontSize: 16.0,
                          fontWeight: FontWeight.bold,
                          color: _isActivityActive ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'Speed: $_currentBandwidth',
                    style: const TextStyle(
                      fontSize: 16.0,
                      fontWeight: FontWeight.bold,
                      color: Colors.blueGrey,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8.0),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0.0), // Adjust padding as needed
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _server != null ? _shareServerUrl : null,
                      icon: const Icon(Icons.share),
                      label: const Text('Share URL'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12.0),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                        backgroundColor: Colors.purple,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16.0), // Space between buttons
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _server != null ? _copyServerUrl : null,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy URL'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12.0),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                        backgroundColor: Colors.teal,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24.0),

            // File Explorer Section
            Text(
              'File Explorer:',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8.0),
            // Refresh button for file explorer
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: _selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                    ? _listFilesAndFolders
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh Files'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8.0)),
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  elevation: 3,
                ),
              ),
            ),
            const SizedBox(height: 8.0),
            // The file explorer list view now needs a defined height or it won't scroll correctly
            // within a SingleChildScrollView. Using a fixed height for demonstration.
            SizedBox(
              height: 200.0, // Fixed height for the file explorer list
              child: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: Colors.blueGrey[900], // Darker background for file list
                  borderRadius: BorderRadius.circular(8.0),
                  border: Border.all(color: Colors.grey, width: 1.0),
                ),
                child: _fileSystemEntries.isEmpty
                    ? Center(
                      child: Text(
                        _selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                            ? 'No files found or directory is empty.'
                            : 'Select a folder to view contents.',
                        style: const TextStyle(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                    )
                    : ListView.builder(
                      controller: _fileExplorerScrollController, // Attach scroll controller
                      itemCount: _fileSystemEntries.length,
                      itemBuilder: (context, index) {
                        final entity = _fileSystemEntries[index];
                        final isDirectory = entity is Directory;
                        final filename = entity.path.split(Platform.pathSeparator).last;
                        return ListTile(
                          leading: Icon(
                            isDirectory ? Icons.folder : Icons.insert_drive_file,
                            color: isDirectory ? Colors.amber : Colors.blueGrey[300],
                          ),
                          title: Text(
                            entity.path.split(Platform.pathSeparator).last, // Just the name
                            style: const TextStyle(color: Colors.white, fontSize: 14.0),
                          ),
                          subtitle: Text(
                            isDirectory ? 'Directory' : 'File',
                            style: const TextStyle(color: Colors.white54, fontSize: 12.0),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 0),
                          dense: true, // Make list items smaller
                          // NEW: onTap handler for text file viewing
                          onTap: () {
                            if (!isDirectory && _isTextFile(entity.path)) {
                              _viewTextFile(entity as File);
                            } else if (isDirectory) {
                              // Optional: Handle tapping directories (e.g., navigate into them)
                              _addLog('Tapped on directory: $filename');
                              // For now, we'll just log. Expanding into subdirectories is a bigger feature.
                            } else {
                              _addLog('Tapped on non-text file: $filename');
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Cannot view "$filename". Only text files are viewable.')),
                              );
                            }
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Download button (only for files)
                              if (!isDirectory)
                                IconButton(
                                  icon: const Icon(Icons.download, color: Colors.blueAccent),
                                  tooltip: 'Download File',
                                  onPressed: () => _downloadFile(entity as File),
                                ),
                              // Delete button (for files and directories)
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.redAccent),
                                tooltip: 'Delete',
                                onPressed: () => _deleteFileSystemEntry(entity),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
              ),
            ),
            const SizedBox(height: 24.0), // Spacer between file explorer and logs

            // Existing Log Display Section
            Text(
              'Server Logs:',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8.0),
            // The log list view also needs a defined height within a SingleChildScrollView.
            SizedBox(
              height: 150.0, // Fixed height for the log list
              child: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.8),
                  borderRadius: BorderRadius.circular(8.0),
                  border: Border.all(color: Colors.grey, width: 1.0),
                ),
                child: ListView.builder(
                  controller: _logScrollController,
                  itemCount: _logMessages.length,
                  itemBuilder: (context, index) {
                    return Text(
                      _logMessages[index],
                      style: const TextStyle(
                        fontFamily: 'monospace', // Monospace for better readability of logs
                        fontSize: 12.0,
                        color: Colors.white,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
