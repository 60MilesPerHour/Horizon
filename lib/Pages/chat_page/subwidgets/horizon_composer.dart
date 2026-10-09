import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:horizon/Services/hermes_commands.dart';
import 'package:horizon/Widgets/horizon_brand.dart';

/// The composer: a floating card with the prompt on top and, beneath it,
/// attach, the model, and one button that changes with what you're doing —
/// the breathing voice orb when there's nothing to send, the orange send
/// button once there is, and stop while a reply is streaming.
class HorizonComposer extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final String? modelLabel;

  /// Provider of the chat's model, so the send button can wear its logo.
  final String? provider;
  final VoidCallback onModelTap;
  final Widget attachButton;
  final bool canSend;
  final bool streaming;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onVoice;

  /// Slash commands matching what's typed, listed over the prompt.
  final List<HermesCommand> commands;
  final ValueChanged<HermesCommand>? onCommand;

  const HorizonComposer({
    super.key,
    required this.controller,
    required this.hint,
    required this.modelLabel,
    this.provider,
    required this.onModelTap,
    required this.attachButton,
    required this.canSend,
    required this.streaming,
    required this.onSend,
    required this.onStop,
    required this.onVoice,
    this.commands = const [],
    this.onCommand,
  });

  @override
  State<HorizonComposer> createState() => _HorizonComposerState();
}

class _HorizonComposerState extends State<HorizonComposer> {
  /// Drafts survive switching chats: each chat's unsent text is kept here,
  /// keyed by the widget key the page gives the composer (the chat id).
  static final PageStorageBucket _drafts = PageStorageBucket();

  bool get _keyed => widget.key is ValueKey && (widget.key as ValueKey).value != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_keyed) return;
      final saved = _drafts.readState(context, identifier: widget.key) as String?;
      if (saved != null && saved.isNotEmpty) widget.controller.text = saved;
    });
  }

  @override
  void deactivate() {
    if (_keyed) _drafts.writeState(context, widget.controller.text, identifier: widget.key);
    super.deactivate();
  }

  /// The voice orb at size 30 plus its 60 % halo; send and stop sit centred
  /// in the same square.
  static const double _actionSlot = 48;

  // Phones: Enter is a new line and the button sends. Desktop: Enter sends,
  // Shift+Enter is a new line.
  bool get _mobile => Platform.isAndroid || Platform.isIOS;

  Widget _commandMenu(ThemeData theme, Color faint) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in widget.commands)
            InkWell(
              onTap: () => widget.onCommand?.call(c),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: '/${c.name}',
                      style: theme.textTheme.bodyMedium?.copyWith(color: HorizonBrand.accent(context)),
                    ),
                    if (c.args != null) TextSpan(text: ' ${c.args}', style: theme.textTheme.bodySmall?.copyWith(color: faint)),
                    TextSpan(text: '  ${c.description}', style: theme.textTheme.bodySmall?.copyWith(color: faint)),
                  ]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          Divider(height: 8, color: theme.colorScheme.outlineVariant.withValues(alpha: .5)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final faint = theme.colorScheme.onSurfaceVariant.withValues(alpha: .7);

    Widget action;
    if (widget.streaming) {
      action = HorizonSendButton(onPressed: widget.onStop, icon: Icons.stop_rounded, tooltip: 'Stop');
    } else if (widget.canSend) {
      action = HorizonSendButton(
        onPressed: widget.onSend,
        provider: widget.provider,
      );
    } else {
      action = VoiceOrb(size: 30, onTap: widget.onVoice, tooltip: 'Horizon Voice');
    }
    // One slot for all three, sized to the orb and its halo. Without it the
    // row shrank 14 px and the button slid sideways the moment you typed.
    action = SizedBox(width: _actionSlot, height: _actionSlot, child: Center(child: action));

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0E0E0E) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: .5)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: dark ? .35 : .08), blurRadius: 24, offset: const Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.commands.isNotEmpty) _commandMenu(theme, faint),
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter, shift: true): () {
                final c = widget.controller;
                final sel = c.selection;
                final at = sel.isValid ? sel.start : c.text.length;
                c.text = c.text.replaceRange(at, sel.isValid ? sel.end : at, '\n');
                c.selection = TextSelection.collapsed(offset: at + 1);
              },
            },
            child: TextField(
              controller: widget.controller,
              minLines: 1,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: _mobile ? TextInputAction.newline : TextInputAction.send,
              onEditingComplete: _mobile ? null : widget.onSend,
              onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w300),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w300, color: faint),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          Row(
            children: [
              widget.attachButton,
              const SizedBox(width: 2),
              // Expanded, not Flexible + Spacer: those split the free space,
              // so the button sat wherever the model name's width left it and
              // moved every time the model changed.
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    onTap: widget.onModelTap,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              widget.modelLabel ?? 'Choose a model',
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: widget.modelLabel == null ? HorizonBrand.accent(context) : faint,
                              ),
                            ),
                          ),
                          Icon(Icons.expand_more, size: 16, color: faint),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              action,
            ],
          ),
        ],
      ),
    );
  }
}
