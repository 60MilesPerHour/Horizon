import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:horizon/Extensions/markdown_stylesheet_extension.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Services/appearance_controller.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'chat_bubble_actions.dart';
import 'chat_bubble_artifact_block.dart';
import 'chat_bubble_attachment.dart';
import 'chat_bubble_code_block.dart';
import 'chat_bubble_image.dart';
import 'chat_bubble_menu.dart';
import 'chat_bubble_think_block.dart';
import 'chat_bubble_tool_card.dart';

final md.ExtensionSet _markdownExtensionSet = md.ExtensionSet(
  <md.BlockSyntax>[
    ThinkBlockSyntax(),
    ArtifactBlockSyntax(),
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
  'artifact': ArtifactBlockBuilder(),
  // `pre` only wraps fenced blocks, so inline `code` keeps the stylesheet's
  // monospace run treatment rather than becoming a highlighted card.
  'pre': CodeBlockBuilder(),
};

class ChatBubble extends StatefulWidget {
  final OllamaMessage message;
  final ValueNotifier<String>? streamingContent;

  /// Whether this bubble should persist its built state when scrolled out
  /// of the cache extent. The caller (ChatListView) decides this per-bubble
  /// so memory doesn't grow unbounded in long chats — see the depth cap in
  /// the SliverList builder.
  final bool keepAlive;

  const ChatBubble({
    super.key,
    required this.message,
    this.streamingContent,
    this.keepAlive = false,
  });

  @override
  State<ChatBubble> createState() => _ChatBubbleState();
}

class _ChatBubbleState extends State<ChatBubble>
    with AutomaticKeepAliveClientMixin<ChatBubble> {
  // Recent bubbles keep their built widget tree (incl. parsed MarkdownBody)
  // so a quick scroll-up doesn't trigger a re-parse cascade. Older bubbles
  // get released to keep the heap bounded — accumulating hundreds of
  // parsed-markdown trees was driving Dart's major GC into multi-second
  // pauses ("UI freezes randomly / after sitting").
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void didUpdateWidget(covariant ChatBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.keepAlive != widget.keepAlive) {
      updateKeepAlive();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    final message = widget.message;
    final streamingContent = widget.streamingContent;

    // Tool steps aren't messages the user wrote or the model said, so the
    // Copy/Edit/Regenerate/Delete menu doesn't apply — editing a tool result
    // would silently rewrite the evidence the answer rests on. A turn with
    // both prose and tool calls keeps the menu and shows the calls above the
    // text; a tool-calls-only turn has nothing to act on.
    if (message.role == OllamaMessageRole.tool ||
        (message.hasToolCalls && message.content.trim().isEmpty)) {
      return _ToolStep(message: message);
    }

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
        MenuItemButton(
          onPressed: () => actions.handleBranch(context),
          leadingIcon: Icon(Icons.call_split),
          child: const Text('Branch from here'),
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
    final appearance = context.watch<AppearanceController>().appearance;
    final bubbled = appearance.userBubbles;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 25.0,
        // Compact density tightens the gap between turns as well as the
        // controls; a transcript-style chat with 15px of air per turn reads as
        // very sparse.
        vertical: appearance.compact ? 8.0 : 15.0,
      ),
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
          // Documents show as chips; tapping one reveals the extracted text
          // that was actually sent.
          if (message.hasAttachments)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment:
                  isSentFromUser ? WrapAlignment.end : WrapAlignment.start,
              children: message.attachments!
                  .map((attachment) => AttachmentChip(attachment: attachment))
                  .toList(),
            ),
          // Mixed turn: the calls it made, then what it said.
          if (message.hasToolCalls) ChatBubbleToolCard(message: message),
          Container(
            // Appearance → "Bubble your messages" off drops the fill and the
            // padding, so the user's turn reads as a transcript line rather
            // than a chat bubble. The assistant's side was never filled.
            padding:
                isSentFromUser && bubbled ? const EdgeInsets.all(10.0) : null,
            constraints: BoxConstraints(
              maxWidth: isSentFromUser
                  ? MediaQuery.of(context).size.width * 0.8
                  : double.infinity,
            ),
            decoration: BoxDecoration(
              color: isSentFromUser && bubbled
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(appearance.cornerRadius),
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

/// A tool call or tool result in the transcript. Deliberately narrower and
/// quieter than a message bubble: these are the machinery behind an answer,
/// not the answer, and they shouldn't compete with it for attention.
class _ToolStep extends StatelessWidget {
  final OllamaMessage message;

  const _ToolStep({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(25.0, 2.0, 25.0, 2.0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520.0),
          child: ChatBubbleToolCard(message: message),
        ),
      ),
    );
  }
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
