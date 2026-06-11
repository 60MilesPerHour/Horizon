import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ChatError extends StatelessWidget {
  final String message;
  final void Function() onRetry;

  const ChatError({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: errorColor),
        borderRadius: BorderRadius.circular(10.0),
      ),
      padding: EdgeInsets.all(10.0),
      margin: EdgeInsets.all(10.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Selectable so the full error can be copied out and acted on.
          SelectableText(
            message,
            style: TextStyle(color: errorColor),
          ),
          const SizedBox(height: 10.0),
          Row(
            children: [
              IconButton(
                tooltip: 'Copy error',
                icon: Icon(Icons.copy, size: 20, color: errorColor),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: message));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Error copied to clipboard')),
                    );
                  }
                },
              ),
              const SizedBox(width: 8.0),
              Expanded(
                child: FilledButton(
                  onPressed: onRetry,
                  style: FilledButton.styleFrom(backgroundColor: errorColor),
                  child: Text('Retry'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
