import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:horizon/Extensions/markdown_stylesheet_extension.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'chat_bubble_actions.dart';
import 'chat_bubble_image.dart';
import 'chat_bubble_menu.dart';
import 'chat_bubble_think_block.dart';

final md.ExtensionSet _markdownExtensionSet = md.ExtensionSet(
  <md.BlockSyntax>[
    ThinkBlockSyntax(),
    ...md.ExtensionSet.gitHubFlavored.blockSyntaxes,
  ],
  <md.InlineSyntax>[
    md.EmojiSyntax(),
    ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
  ],
);

final TextStyle _markdownCodeStyle = GoogleFonts.sourceCodePro();

final Map<String, MarkdownElementBuilder> _markdownBuilders = {
  'think': ThinkBlockBuilder(),
};

class ChatBubble extends StatefulWidget {
  final OllamaMessage message;
  final ValueNotifier<String>? streamingContent;

  const ChatBubble({
    super.key,
    required this.message,
    this.streamingContent,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble>
    with AutomaticKeepAliveClientMixin<ChatBubble> {
  // Once a bubble has been built (and its MarkdownBody parsed), keep it in
  // memory even when scrolled out of the cache extent. Without this, fast
  // scrolling causes bubbles to be destroyed and re-parsed from scratch on
  // re-entry, which manifests as text disappearing during scroll and
  // "cascading" back in one bubble at a time once scroll stops.
  //
  // Streaming bubbles intentionally don't keep alive — they rebuild every
  // typewriter tick by design via the ValueListenableBuilder, and keeping
  // them alive offers no benefit. Static bubbles are the expensive ones.
  @override
  bool get wantKeepAlive => widget.streamingContent == null;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final message = widget.message;
    final streamingContent = widget.streamingContent;
    final actions = ChatBubbleActions(message);

    return ChatBubbleMenu(
      menuChildren: [
        MenuItemButton(
          onPressed: actions.handleCopy,
          leadingIcon: Icon(Icons.copy_outlined),
          child: const Text('Copy'),
        ),
        MenuItemButton(
          onPressed: () => actions.handleSelectText(context),
          leadingIcon: Icon(Icons.select_all_outlined),
          child: const Text('Select Text'),
        ),
        MenuItemButton(
          onPressed: () => actions.handleRegenerate(context),
          leadingIcon: Icon(Icons.refresh_outlined),
          child: const Text('Regenerate'),
        ),
        Divider(),
        MenuItemButton(
          onPressed: () => actions.handleEdit(context),
          closeOnActivate: false,
          leadingIcon: Icon(Icons.edit_outlined),
          child: const Text('Edit'),
        ),
        MenuItemButton(
          onPressed: () => actions.handleDelete(context),
          leadingIcon: Icon(Icons.delete_outline),
          child: const Text('Delete'),
        ),
      ],
      child: _ChatBubbleBody(message: message, streamingContent: streamingContent),
    );
  }
}

class _ChatBubbleBody extends StatelessWidget {
  final OllamaMessage message;
  final ValueNotifier<String>? streamingContent;

  const _ChatBubbleBody({super.key, required this.message, this.streamingContent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25.0, vertical: 15.0),
      child: Column(
        spacing: 8,
        crossAxisAlignment: bubbleAlignment,
        children: [
          // If the message has an image attachment, display it
          if (message.images != null && message.images!.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: message.images!
                  .map((imageFile) => ChatBubbleImage(imageFile: imageFile))
                  .toList(),
            ),
          Container(
            padding: isSentFromUser ? const EdgeInsets.all(10.0) : null,
            constraints: BoxConstraints(
              maxWidth: isSentFromUser
                  ? MediaQuery.of(context).size.width * 0.8
                  : double.infinity,
            ),
            decoration: BoxDecoration(
              color: isSentFromUser
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(10.0),
            ),
            child: streamingContent != null
                ? _StreamingText(notifier: streamingContent!)
                : MarkdownBody(
                    data: message.content,
                    // selectable: true wraps the body in SelectableText, whose
                    // gesture recognizer fights the parent Scrollable in the
                    // gesture arena — scroll attempts that start on a bubble
                    // intermittently get swallowed by text-selection logic.
                    // The long-press menu's "Select Text" option already opens
                    // a dedicated SelectableText sheet, so the bubble itself
                    // doesn't need to be selectable.
                    selectable: false,
                    softLineBreak: true,
                    styleSheet: context.markdownStyleSheet.copyWith(
                      code: _markdownCodeStyle,
                    ),
                    builders: _markdownBuilders,
                    extensionSet: _markdownExtensionSet,
                    onTapLink: (text, href, title) => launchUrlString(href!),
                  ),
          ),
          Text(
            TimeOfDay.fromDateTime(message.createdAt.toLocal()).format(context),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Returns true if the message is sent from the user.
  bool get isSentFromUser => message.role == OllamaMessageRole.user;

  /// Returns the alignment of the bubble.
  ///
  /// If the message is sent from the user, the alignment is [Alignment.centerRight].
  /// Otherwise, the alignment is [Alignment.centerLeft].
  CrossAxisAlignment get bubbleAlignment =>
      isSentFromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
}

/// Plain-text view of the in-flight streaming response.
///
/// During streaming the message can grow to thousands of characters; piping
/// every typewriter tick through `flutter_markdown` reparses the entire string
/// each frame and creates the "slideshow" feel. Render as raw text while the
/// stream runs, then `ChatBubble` swaps to `MarkdownBody` once the notifier is
/// detached (i.e., generation finished).
class _StreamingText extends StatelessWidget {
  final ValueNotifier<String> notifier;

  const _StreamingText({required this.notifier});

  @override
  Widget build(BuildContext context) {
    final baseStyle = Theme.of(context).textTheme.bodyMedium;
    return ValueListenableBuilder<String>(
      valueListenable: notifier,
      builder: (context, content, _) => Text(
        content,
        softWrap: true,
        style: baseStyle,
      ),
    );
  }
}
