import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
// NEW imports for services/widgets
import 'package:msa/services/preference_service.dart';
import 'package:msa/services/permission_service.dart';
import 'package:msa/widgets/log_display.dart'; // Import the new LogDisplay widget

// ServerHomePage now receives a callback to toggle the theme and an initial theme mode
class ServerHomePage extends StatefulWidget {
  final Function(bool) toggleTheme;
  final ThemeMode initialThemeMode;

  const ServerHomePage({
    super.key,
    required this.toggleTheme,
    required this.initialThemeMode,
  });

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
  String? _custom404FilePath;
  String? _custom404HtmlContent;

  String? _serverIpAddress;

  double _bytesTransferredThisSecond = 0;
  String _currentBandwidth = '0 KB/s';
  bool _isActivityActive = false;
  Timer? _activityTimer;
  Timer? _bandwidthTimer;

  // Instances of our new services
  late PreferenceService _preferenceService;
  late PermissionService _permissionService;

  // List to store log messages
  final List<String> _logMessages = [];
  final ScrollController _logScrollController = ScrollController();

  // List to store file system entries for the explorer
  List<FileSystemEntity> _fileSystemEntries = [];
  final ScrollController _fileExplorerScrollController = ScrollController();

  late bool _isDarkMode;

  @override
  void initState() {
    super.initState();
    _isDarkMode = widget.initialThemeMode == ThemeMode.dark;

    _preferenceService = PreferenceService(); // Initialize preference service
    _permissionService = PermissionService(_addLog); // Initialize permission service with logger

    _initPreferencesAndLoad();

    _hostnameController.addListener(() => _savePreference('hostname', _hostnameController.text));
    _portController.addListener(() => _savePreference('port', _portController.text));
  }

  @override
  void dispose() {
    _hostnameController.removeListener(() => _savePreference('hostname', _hostnameController.text));
    _portController.removeListener(() => _savePreference('port', _portController.text));

    _stopServer();
    _logScrollController.dispose();
    _fileExplorerScrollController.dispose();
    _activityTimer?.cancel();
    _bandwidthTimer?.cancel();
    super.dispose();
  }

  // Initializes SharedPreferences and loads saved data
  Future<void> _initPreferencesAndLoad() async {
    await _preferenceService.init(); // Initialize the preference service
    await _loadSavedPreferences();
  }

  // Loads saved preferences from SharedPreferences
  Future<void> _loadSavedPreferences() async {
    _addLog('Loading saved preferences...');
    setState(() {
      _hostnameController.text = _preferenceService.getString('hostname') ?? '0.0.0.0';
      _portController.text = _preferenceService.getString('port') ?? '8080';
      _selectedDirectoryPath = _preferenceService.getString('selectedDirectoryPath');
      _custom404FilePath = _preferenceService.getString('custom404FilePath');
      final loadedIsDarkMode = _preferenceService.getBool('isDarkMode');
      if (_isDarkMode != loadedIsDarkMode) {
        _isDarkMode = loadedIsDarkMode;
      }
    });
    widget.toggleTheme(_isDarkMode);

    if (_selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty) {
      _addLog('Loaded saved folder: $_selectedDirectoryPath');
      _listFilesAndFolders();
    }
    if (_custom404FilePath != null && _custom404FilePath!.isNotEmpty) {
      _addLog('Loaded saved 404 page: $_custom404FilePath');
    }
  }

  // Helper to save a single preference
  Future<void> _savePreference(String key, dynamic value) async {
    if (value is String) {
      await _preferenceService.setString(key, value);
    } else if (value is bool) {
      await _preferenceService.setBool(key, value);
    } else {
      // Handle other types or remove if not string/bool
      _addLog('Attempted to save unsupported preference type for key: $key');
    }
    _addLog('Saved preference: $key = $value');
  }

  // Toggle theme and save preference
  void _toggleTheme() {
    setState(() {
      _isDarkMode = !_isDarkMode;
    });
    _savePreference('isDarkMode', _isDarkMode);
    widget.toggleTheme(_isDarkMode);
    _addLog('Theme toggled to ${_isDarkMode ? "Dark" : "Light"} Mode.');
  }

  /// Adds a log message to the log display and scrolls to the bottom.
  void _addLog(String message) {
    setState(() {
      _logMessages.add('${DateTime.now().toIso8601String().substring(11, 19)} - $message');
      if (_logMessages.length > 200) {
        _logMessages.removeAt(0);
      }
    });
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

  // Helper to determine if a file is text-based by its extension
  bool _isTextFile(String filePath) {
    final textExtensions = const [
      '.txt', '.log', '.csv', '.json', '.xml', '.yaml', '.yml',
      '.html', '.htm', '.css', '.js', '.ts', '.dart', '.java', '.py', '.c', '.cpp', '.h', '.hpp',
      '.md', '.sh', '.bat', '.ps1', '.sql', '.php', '.go', '.rb', '.rs', '.swift',
      '.toml', '.ini', '.cfg', '.conf', '.env', '.gitignore'
    ];
    final extension = filePath.toLowerCase().split('.').last;
    return textExtensions.contains('.$extension');
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
            title: Text(file.path.split(Platform.pathSeparator).last),
            content: SizedBox(
              width: MediaQuery.of(context).size.width * 0.8,
              height: MediaQuery.of(context).size.height * 0.6,
              child: SingleChildScrollView(
                child: Text(
                  content,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12.0),
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


  /// Requests storage permissions (now handled by PermissionService).
  Future<bool> _requestStoragePermissionWrapper() async {
    return await _permissionService.requestStoragePermission(context);
  }


  /// Opens a file picker to allow the user to select a directory.
  Future<void> _pickDirectory() async {
    bool granted = await _requestStoragePermissionWrapper(); // Use the wrapper
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
        _savePreference('selectedDirectoryPath', _selectedDirectoryPath);
        _listFilesAndFolders();
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

  /// Picks a custom 404 HTML file.
  Future<void> _pickCustom404File() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['html', 'htm'],
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        _addLog('Selected custom 404 file: $filePath');
        await _readCustom404Content(filePath);

        setState(() {
          _custom404FilePath = filePath;
        });
        _savePreference('custom404FilePath', _custom404FilePath);
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

  /// Reads content of the custom 404 HTML file.
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
      contents.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
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

  /// Downloads a file by launching its URL in the default browser.
  Future<void> _downloadFile(File file) async {
    if (_serverIpAddress == null || _selectedDirectoryPath == null) {
      _addLog('Download failed: Server not running or no directory selected.');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server not active or directory not selected.'), duration: Duration(seconds: 3)),
      );
      return;
    }

    final relativePath = file.path.substring(_selectedDirectoryPath!.length);
    final urlPath = relativePath.startsWith(Platform.pathSeparator)
        ? relativePath.substring(Platform.pathSeparator.length)
        : relativePath;

    final urlString = 'http://$_serverIpAddress:${_portController.text}/$urlPath';
    _addLog('Attempting to download: $urlString');

    final uri = Uri.parse(urlString);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      _addLog('Download link launched: $urlString');
    } else {
      _addLog('Could not launch download URL: $urlString');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open download link for ${file.path.split(Platform.pathSeparator).last}'), duration: Duration(seconds: 3)),
      );
    }
  }

  /// Deletes a file or an empty directory after user confirmation.
  Future<void> _deleteFileSystemEntry(FileSystemEntity entity) async {
    _addLog('Attempting to delete: ${entity.path}');

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
        false;

    if (!confirm) {
      _addLog('Deletion cancelled for: ${entity.path}');
      return;
    }

    try {
      if (entity is File) {
        await entity.delete();
        _addLog('Successfully deleted file: ${entity.path}');
      } else if (entity is Directory) {
        if ((await entity.list().isEmpty)) {
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
      _listFilesAndFolders();
    } catch (e, st) {
      _addLog('Error deleting ${entity.path}: $e');
      print('Deletion error: $e\n$st');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete: ${entity.path.split(Platform.pathSeparator).last}'), duration: Duration(seconds: 4)),
      );
    }
  }

  // Gets the current server URL string for sharing/copying
  String? _getServerUrl() {
    if (_serverIpAddress != null && _portController.text.isNotEmpty) {
      return 'http://$_serverIpAddress:${_portController.text}/';
    }
    return null;
  }

  // Shares the server URL using native share sheet
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

  // Copies the server URL to clipboard
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

  // Shelf Middleware to count bytes transferred
  Middleware _countingMiddleware() {
    return (innerHandler) {
      return (Request request) async {
        final response = await innerHandler(request);

        final originalStream = response.read();
        final countingStream = originalStream.transform<List<int>>(
          StreamTransformer.fromHandlers(
            handleData: (List<int> data, EventSink<List<int>> sink) {
              setState(() {
                _bytesTransferredThisSecond += data.length;
                _isActivityActive = true;
                _activityTimer?.cancel();
                _activityTimer = Timer(const Duration(milliseconds: 500), () {
                  setState(() {
                    _isActivityActive = false;
                  });
                });
              });
              sink.add(data);
            },
            handleError: (error, stackTrace, sink) {
              sink.addError(error, stackTrace);
            },
            handleDone: (sink) {
              sink.close();
            },
          ),
        );
        return response.change(body: countingStream);
      };
    };
  }

  // Function to calculate and update bandwidth display
  void _updateBandwidth(Timer timer) {
    setState(() {
      if (_bytesTransferredThisSecond > 0) {
        final speedKBps = _bytesTransferredThisSecond / 1024;
        if (speedKBps >= 1024) {
          _currentBandwidth = '${(speedKBps / 1024).toStringAsFixed(2)} MB/s';
        } else {
          _currentBandwidth = '${speedKBps.toStringAsFixed(2)} KB/s';
        }
        _bytesTransferredThisSecond = 0;
      } else {
        _currentBandwidth = '0 KB/s';
      }
    });
  }


  /// Starts the HTTP server on the specified hostname and port.
  Future<void> _startServer() async {
    await _stopServer();
    _logMessages.clear();
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
      if (_custom404FilePath != null) {
        await _readCustom404Content(_custom404FilePath!);
      } else {
        _custom404HtmlContent = null;
      }

      _bandwidthTimer?.cancel();
      _bandwidthTimer = Timer.periodic(const Duration(seconds: 1), _updateBandwidth);

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
            .add((Request request) {
          final path = request.url.pathSegments.join('/');
          if (path == 'upload' && request.method == 'POST') {
            _addLog('Routing POST request to _handleUploadRequest for /upload');
            return _handleUploadRequest(request);
          } else if (path == 'upload.html' && request.method == 'GET') {
            _addLog('Serving upload form for GET request to /upload.html');
            return Response.ok(_getUploadFormHtml(), headers: {'Content-Type': 'text/html'});
          }
          return Response.notFound('');
        })
            .add(createStaticHandler(_selectedDirectoryPath!, defaultDocument: 'index.html'))
            .add((Request request) {
          _addLog('Custom 404 Handler: Path not found by previous handlers: ${request.url.path}');
          if (_custom404HtmlContent != null) {
            return Response(HttpStatus.notFound, headers: {'Content-Type': 'text/html'}, body: _custom404HtmlContent);
          }
          return Response.notFound('Not Found');
        })
            .handler);

      } else {
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
          if (_custom404HtmlContent != null) {
            return Response(HttpStatus.notFound, headers: {'Content-Type': 'text/html'}, body: _custom404HtmlContent);
          }
          return Response.notFound('Not Found');
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
        });
        _server = null;
        _serverIpAddress = null;
        _addLog('Server successfully stopped.');
        setState(() {
          _fileSystemEntries = [];
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

  @override
  Widget build(BuildContext context) {
    // Determine current brightness for dynamic colors
    final currentBrightness = Theme.of(context).brightness;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Minimal Server App'),
        centerTitle: true,
        actions: [
          // Theme toggle switch
          IconButton(
            icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode),
            onPressed: _toggleTheme,
            tooltip: _isDarkMode ? 'Switch to Light Mode' : 'Switch to Dark Mode',
          ),
        ],
      ),
      body: SingleChildScrollView(
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
                fillColor: currentBrightness == Brightness.light ? Colors.grey[100] : Colors.grey[700],
              ),
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color),
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
                fillColor: currentBrightness == Brightness.light ? Colors.grey[100] : Colors.grey[700],
              ),
              keyboardType: TextInputType.number,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              textInputAction: TextInputAction.done,
              style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color),
            ),
            const SizedBox(height: 24.0),
            // Choose Folder Button
            ElevatedButton.icon(
              onPressed: _server == null ? _pickDirectory : null,
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
                color: currentBrightness == Brightness.light ? Colors.blueGrey[50] : Colors.grey[850],
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(color: currentBrightness == Brightness.light ? Colors.blueGrey : Colors.grey[700]!, width: 1.0),
              ),
              child: Text(
                _selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                    ? 'Selected Folder: $_selectedDirectoryPath'
                    : 'No folder selected. Serving default content.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.0,
                  color: currentBrightness == Brightness.light
                      ? Colors.blueGrey[800]
                      : Colors.white70,
                  fontStyle: _selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                      ? FontStyle.normal
                      : FontStyle.italic,
                ),
              ),
            ),
            const SizedBox(height: 24.0),

            // Choose 404 Page Button
            ElevatedButton.icon(
              onPressed: _server == null ? _pickCustom404File : null,
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
            // Display selected 404 file path
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: currentBrightness == Brightness.light ? Colors.orange[50] : Colors.grey[850],
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(color: currentBrightness == Brightness.light ? Colors.orange : Colors.grey[700]!, width: 1.0),
              ),
              child: Text(
                _custom404FilePath != null && _custom404FilePath!.isNotEmpty
                    ? 'Custom 404 Page: $_custom404FilePath'
                    : 'No custom 404 page selected. Default "Not Found" will be used.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14.0,
                  color: currentBrightness == Brightness.light
                      ? Colors.orange[800]
                      : Colors.white70,
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
            const SizedBox(height: 16.0),

            // Activity and Bandwidth Display
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: currentBrightness == Brightness.light ? Colors.blue[50] : Colors.grey[850],
                borderRadius: BorderRadius.circular(8.0),
                border: Border.all(color: currentBrightness == Brightness.light ? Colors.blue : Colors.grey[700]!, width: 1.0),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        _isActivityActive ? Icons.wifi_protected_setup : Icons.wifi_off,
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
                    style: TextStyle(
                      fontSize: 16.0,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).textTheme.bodyMedium?.color,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24.0),

            // Share and Copy URL Buttons
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 0.0),
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
                  const SizedBox(width: 16.0),
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
            SizedBox(
              height: 200.0,
              child: Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: currentBrightness == Brightness.light ? Colors.blueGrey[50] : Colors.blueGrey[900],
                  borderRadius: BorderRadius.circular(8.0),
                  border: Border.all(color: currentBrightness == Brightness.light ? Colors.blueGrey : Colors.grey[700]!, width: 1.0),
                ),
                child: _fileSystemEntries.isEmpty
                    ? Center(
                  child: Text(
                    _selectedDirectoryPath != null && _selectedDirectoryPath!.isNotEmpty
                        ? 'No files found or directory is empty.'
                        : 'Select a folder to view contents.',
                    style: TextStyle(color: currentBrightness == Brightness.light ? Colors.grey[600] : Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                )
                    : ListView.builder(
                  controller: _fileExplorerScrollController,
                  itemCount: _fileSystemEntries.length,
                  itemBuilder: (context, index) {
                    final entity = _fileSystemEntries[index];
                    final isDirectory = entity is Directory;
                    final filename = entity.path.split(Platform.pathSeparator).last;

                    return ListTile(
                      leading: Icon(
                        isDirectory ? Icons.folder : Icons.insert_drive_file,
                        color: isDirectory ? Colors.amber : (currentBrightness == Brightness.light ? Colors.blueGrey[600] : Colors.blueGrey[300]),
                      ),
                      title: Text(
                        filename,
                        style: TextStyle(color: Theme.of(context).textTheme.bodyMedium?.color, fontSize: 14.0),
                      ),
                      subtitle: Text(
                        isDirectory ? 'Directory' : 'File',
                        style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color, fontSize: 12.0),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 0),
                      dense: true,
                      onTap: () {
                        if (!isDirectory && _isTextFile(entity.path)) {
                          _viewTextFile(entity as File);
                        } else if (isDirectory) {
                          _addLog('Tapped on directory: $filename');
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
                          if (!isDirectory)
                            IconButton(
                              icon: const Icon(Icons.download, color: Colors.blueAccent),
                              tooltip: 'Download File',
                              onPressed: () => _downloadFile(entity as File),
                            ),
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
            const SizedBox(height: 24.0),

            // Existing Log Display Section (now uses LogDisplay widget)
            LogDisplay(
              logMessages: _logMessages,
              scrollController: _logScrollController,
              brightness: currentBrightness,
            ),
          ],
        ),
      ),
    );
  }
}