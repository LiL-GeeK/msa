import 'package:flutter/material.dart';

// A widget to display a scrollable list of log messages.
class LogDisplay extends StatelessWidget {
  final List<String> logMessages;
  final ScrollController scrollController;
  final Brightness brightness; // To adapt text color to theme

  const LogDisplay({
    super.key,
    required this.logMessages,
    required this.scrollController,
    required this.brightness, // Pass brightness for conditional styling
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Server Logs:',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8.0),
        SizedBox(
          height: 150.0, // Fixed height for the log list
          child: Container(
            padding: const EdgeInsets.all(8.0),
            decoration: BoxDecoration(
              color: brightness == Brightness.light ? Colors.black.withOpacity(0.8) : Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(8.0),
              border: Border.all(color: Colors.grey, width: 1.0),
            ),
            child: ListView.builder(
              controller: scrollController,
              itemCount: logMessages.length,
              itemBuilder: (context, index) {
                return Text(
                  logMessages[index],
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12.0,
                    color: Colors.white, // Logs text always white for dark background
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}