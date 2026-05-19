import 'package:flutter/material.dart';
import 'package:horizon/Models/ollama_message.dart' show OllamaMessage, OllamaMessageRole;
import 'package:shimmer/shimmer.dart';
import 'package:notification_centre/notification_centre.dart';

import 'chat_bubble/chat_bubble.dart';
import 'package:horizon/Constants/constants.dart';

/// Stick-to-bottom chat list.
///
/// Uses a plain `reverse: true` ListView — offset 0 IS the visual bottom, so
/// content growth at the bottom keeps the user pinned automatically. The
/// streaming bubble rebuilds via a ValueNotifier in [ChatBubble], so the rest
/// of the list never repaints during a token stream.
class ChatListView extends StatefulWidget {
  final List<OllamaMessage> messages;
  final bool isAwaitingReply;
  final Widget? error;
  final double? bottomPadding;
  final ValueNotifier<String>? streamingContent;

  const ChatListView({
    super.key,
    required this.messages,
    required this.isAwaitingReply,
    this.error,
    this.bottomPadding,
    this.streamingContent,
  });

  @override
  State<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends State<ChatListView> {
  final ScrollController _scrollController = ScrollController();

  /// User is considered "at the bottom" when their scroll offset is within
  /// this many pixels of 0 (which, in a reverse list, is the visual bottom).
  static const double _bottomThreshold = 80.0;

  /// True when the scroll-to-bottom button should be visible.
  bool _showScrollButton = false;

  @override
  void initState() {
    super.initState();

    _scrollController.addListener(_onScroll);

    // When the user fires off a new prompt, slide them down to the bottom so
    // they see the newly-sent message and the incoming response. Mid-stream
    // growth is handled by `reverse: true` itself — offset 0 naturally tracks
    // the latest content, no per-tick snapping required.
    NotificationCenter().addObserver(
      NotificationNames.generationBegin,
      this,
      (n) => _snapToBottom(animated: true),
    );
  }

  @override
  void didUpdateWidget(covariant ChatListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // On chat switch / message edits, recompute button visibility.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void dispose() {
    NotificationCenter().removeObserver(NotificationNames.generationBegin, this);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.position.pixels;
    final nearBottom = offset <= _bottomThreshold;

    final shouldShow = !nearBottom;
    if (shouldShow != _showScrollButton) {
      setState(() => _showScrollButton = shouldShow);
    }
  }

  void _snapToBottom({bool animated = false}) {
    if (!_scrollController.hasClients) return;
    if (animated) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _scrollController.jumpTo(0.0);
    }
    if (_showScrollButton) setState(() => _showScrollButton = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CustomScrollView(
          controller: _scrollController,
          reverse: true,
          // Default cacheExtent (250 px) is far too small for long story-
          // length messages — bubbles fall out of cache during fast scroll
          // and have to re-parse their markdown on re-entry, which is what
          // the user sees as "text goes bye, animates back when scroll
          // stops." 2000 px keeps several screens worth of bubbles built
          // ahead of the viewport. AutomaticKeepAlive in ChatBubble handles
          // the rest by preserving already-built bubbles past the cache edge.
          cacheExtent: 2000,
          // Inherit platform-default physics (Clamping + stretch overscroll
          // on Android, Bouncing on iOS/macOS). Hard-coding BouncingScrollPhysics
          // here made Android feel un-Material; remove the override.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (widget.bottomPadding != null)
              SliverPadding(
                padding: EdgeInsets.only(bottom: widget.bottomPadding!),
              ),
            if (widget.error != null)
              SliverToBoxAdapter(child: widget.error),
            if (widget.isAwaitingReply)
              SliverToBoxAdapter(
                child: Shimmer.fromColors(
                  baseColor: Theme.of(context).colorScheme.onPrimary,
                  highlightColor: Theme.of(context).colorScheme.onSurface,
                  period: const Duration(milliseconds: 2500),
                  child: const ListTile(
                    title: Padding(
                      padding: EdgeInsets.all(10.0),
                      child: Text("Thinking"),
                    ),
                  ),
                ),
              ),
            SliverList.builder(
              itemCount: widget.messages.length,
              itemBuilder: (context, index) {
                final message = widget.messages[widget.messages.length - index - 1];
                // Only attach the streamingContent notifier when the bottom
                // message is the in-flight ASSISTANT response. Without the
                // role check, a freshly-sent user prompt at index 0 would
                // attach the notifier and paint the previous response's
                // leftover text on top of the user's actual prompt during
                // the gap before the first token arrives.
                final notifier = (index == 0 &&
                        message.role == OllamaMessageRole.assistant)
                    ? widget.streamingContent
                    : null;
                return RepaintBoundary(
                  key: ValueKey(message.id),
                  child: ChatBubble(
                    message: message,
                    streamingContent: notifier,
                  ),
                );
              },
            ),
          ],
        ),
        // Bottom-right corner so it never obscures streaming text. Sized
        // down from a default IconButton (48dp) to a small FAB so it sits
        // out of the reading flow but stays tappable. Slight opacity lets
        // the user see what's underneath when the bubble is wide.
        if (_showScrollButton)
          Positioned(
            right: 12.0,
            bottom: 12.0,
            child: Opacity(
              opacity: 0.92,
              child: FloatingActionButton.small(
                heroTag: 'horizon_scroll_to_bottom',
                onPressed: () => _snapToBottom(animated: true),
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                foregroundColor: Theme.of(context).colorScheme.onSurface,
                elevation: 2,
                child: const Icon(Icons.arrow_downward_rounded),
              ),
            ),
          ),
      ],
    );
  }
}
