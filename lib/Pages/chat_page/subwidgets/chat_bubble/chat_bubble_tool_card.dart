import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/ollama_message.dart';

/// Renders a tool step in the transcript.
///
/// Two shapes, both compact by default: the assistant turn that *asked* for
/// tools, and the result that came back. Results collapse — a fetched page can
/// be 8,000 characters and nobody wants that inlined in a chat — but they stay
/// openable, because "the model said the tool told it X" is exactly the claim
/// you want to be able to check.
class ChatBubbleToolCard extends StatelessWidget {
  final OllamaMessage message;

  const ChatBubbleToolCard({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    if (message.role == OllamaMessageRole.tool) {
      return _ToolResultCard(message: message);
    }
    return _ToolCallCard(calls: message.toolCalls ?? const []);
  }
}

/// "Called web_search(…)" — the request side. Not collapsible: it's one line,
/// and the arguments are the interesting part of a call.
class _ToolCallCard extends StatelessWidget {
  final List<ToolCall> calls;

  const _ToolCallCard({required this.calls});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final call in calls)
          Padding(
            padding: const EdgeInsets.only(bottom: 4.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2.0, right: 6.0),
                  child: Icon(
                    _iconFor(call.name),
                    size: 15.0,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: Text(
                    _describe(call),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Plain-English description per known tool, falling back to the raw call
  /// so a tool added later still reads sensibly without touching this file.
  static String _describe(ToolCall call) {
    switch (call.name) {
      case 'web_search':
        final query = call.arguments['query']?.toString() ?? '';
        return query.isEmpty ? 'Searched the web' : 'Searched for "$query"';
      case 'web_fetch':
        final url = call.arguments['url']?.toString() ?? '';
        final host = Uri.tryParse(url)?.host ?? '';
        return host.isEmpty ? 'Fetched a page' : 'Read $host';
      case 'current_time':
        return 'Checked the current time';
      default:
        return 'Called ${call.summary}';
    }
  }

  static IconData _iconFor(String name) {
    switch (name) {
      case 'web_search':
        return Icons.travel_explore_outlined;
      case 'web_fetch':
        return Icons.article_outlined;
      case 'current_time':
        return Icons.schedule_outlined;
      default:
        return Icons.handyman_outlined;
    }
  }
}

class _ToolResultCard extends StatefulWidget {
  final OllamaMessage message;

  const _ToolResultCard({required this.message});

  @override
  State<_ToolResultCard> createState() => _ToolResultCardState();
}

class _ToolResultCardState extends State<_ToolResultCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = widget.message.toolFailed;
    final accent =
        failed ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;

    final lineCount = widget.message.content.split('\n').length;
    final summary = failed
        ? 'Tool failed'
        : '${widget.message.toolName ?? 'Tool'} returned '
            '${widget.message.content.length} characters';

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(
          color: failed
              ? theme.colorScheme.error.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant,
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10.0,
                vertical: 8.0,
              ),
              child: Row(
                children: [
                  Icon(
                    failed
                        ? Icons.error_outline
                        : Icons.check_circle_outline,
                    size: 15.0,
                    color: accent,
                  ),
                  const SizedBox(width: 6.0),
                  Expanded(
                    child: Text(
                      summary,
                      style: theme.textTheme.bodySmall?.copyWith(color: accent),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18.0,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 0.5, color: theme.colorScheme.outlineVariant),
            // Capped so a long fetch can't turn one message into a page of
            // scrolling; the content scrolls within the cap instead.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: lineCount > 12 ? 260.0 : double.infinity,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10.0),
                child: SelectableText(
                  widget.message.content,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Divider(height: 0.5, color: theme.colorScheme.outlineVariant),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: widget.message.content),
                ),
                icon: const Icon(Icons.copy_outlined, size: 15.0),
                label: const Text('Copy'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelSmall,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
