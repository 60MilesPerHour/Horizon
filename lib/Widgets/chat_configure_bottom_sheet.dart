import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:horizon/Models/chat_configure_arguments.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Pages/chat_page/chat_page_view_model.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/chat_export_service.dart';
import 'package:horizon/Services/web_search_service.dart';
import 'package:horizon/Widgets/flexible_text.dart';

import 'ollama_bottom_sheet_header.dart';

class ChatConfigureBottomSheet extends StatelessWidget {
  final ChatConfigureArguments arguments;

  const ChatConfigureBottomSheet({super.key, required this.arguments});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.58,
      ),
      child: SafeArea(
        bottom: false,
        minimum: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OllamaBottomSheetHeader(title: 'Configure The Chat'),
            Divider(),
            Expanded(
              child: _ChatConfigureBottomSheetContent(arguments: arguments),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChatConfigureBottomSheetContent extends StatefulWidget {
  final ChatConfigureArguments arguments;

  const _ChatConfigureBottomSheetContent({
    super.key,
    required this.arguments,
  });

  @override
  State<_ChatConfigureBottomSheetContent> createState() => __ChatConfigureBottomSheetContentState();
}

class __ChatConfigureBottomSheetContentState extends State<_ChatConfigureBottomSheetContent> {
  late OllamaChatOptions _chatOptions;

  final _scrollController = ScrollController();
  bool _showAdvancedConfigurations = false;

  @override
  void initState() {
    super.initState();

    _chatOptions = widget.arguments.chatOptions;
  }

  @override
  void dispose() {
    _scrollController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 16.0),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        // Rename / Export / Delete row.
        Row(
          spacing: 16.0,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: _RenameButton()),
            Expanded(child: _ExportButton()),
            Expanded(child: _DeleteButton()),
          ],
        ),
        // The chat configurations section
        const SizedBox(height: 16),
        _WebSearchTile(
          value: _chatOptions.webSearch,
          onChanged: (v) => setState(() => _chatOptions.webSearch = v),
        ),
        const SizedBox(height: 16),
        _ArtifactsTile(
          value: _chatOptions.artifacts,
          onChanged: (v) => setState(() => _chatOptions.artifacts = v),
        ),
        const SizedBox(height: 16),
        _BottomSheetTextField(
          initialValue: widget.arguments.systemPrompt,
          labelText: 'System Prompt',
          infoText:
              'The system prompt is the message that the AI will see before generating a response. It is used to provide context to the AI.',
          type: _BottomSheetTextFieldType.text,
          onChanged: (value) => widget.arguments.systemPrompt = value ?? '',
        ),
        const SizedBox(height: 16),
        Divider(),
        const SizedBox(height: 16),
        _BottomSheetTextField(
          initialValue: _chatOptions.temperature,
          labelText: 'Temperature',
          infoText:
              'The temperature of the model. Increasing the temperature will make the model answer more creatively.',
          type: _BottomSheetTextFieldType.decimalBetween0And1,
          onChanged: (v) => _chatOptions.temperature = v ?? 0.8,
        ),
        const SizedBox(height: 16),
        _BottomSheetTextField(
          initialValue: _chatOptions.seed,
          labelText: 'Seed',
          infoText:
              'Sets the random number seed to use for generation. Setting this to a specific number will make the model generate the same text for the same prompt.',
          type: _BottomSheetTextFieldType.number,
          onChanged: (v) => _chatOptions.seed = v ?? 0,
        ),
        // The advanced configurations section
        TextButton(
          onPressed: () {
            setState(() {
              _showAdvancedConfigurations = !_showAdvancedConfigurations;

              _scrollController.animateTo(
                _showAdvancedConfigurations
                    ? _scrollController.position.pixels + 100
                    : _scrollController.position.minScrollExtent,
                duration: const Duration(milliseconds: 500),
                curve: Curves.ease,
              );
            });
          },
          child: Text(
            _showAdvancedConfigurations ? 'Hide Advanced Configurations' : 'Show Advanced Configurations',
          ),
        ),
        if (_showAdvancedConfigurations) ...[
          _BottomSheetTextField(
            initialValue: _chatOptions.maxTokens,
            labelText: 'Max Tokens',
            infoText: 'Maximum number of tokens to predict when generating text. -1 = infinite generation.',
            type: _BottomSheetTextFieldType.number,
            onChanged: (v) => _chatOptions.maxTokens = v ?? -1,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.repeatLastN,
            labelText: 'Repeat Last N',
            infoText: 'How far back the model looks to prevent repetition. 0 = disabled, -1 = full context size.',
            type: _BottomSheetTextFieldType.number,
            onChanged: (v) => _chatOptions.repeatLastN = v ?? 64,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.contextSize,
            labelText: 'Context Size',
            infoText:
                'Size of the context window. Leave at 0 to use whatever your server has loaded (recommended) — Ollama otherwise unloads and reloads the model to honour this override.',
            type: _BottomSheetTextFieldType.number,
            onChanged: (v) => _chatOptions.contextSize = v ?? 0,
          ),
          const SizedBox(height: 16),
          _ThinkingModeTile(
            value: _chatOptions.think,
            onChanged: (v) => setState(() => _chatOptions.think = v),
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.repeatPenalty,
            labelText: 'Repeat Penalty',
            infoText: 'The penalty for repeating tokens in the output text. 0 = disabled.',
            type: _BottomSheetTextFieldType.decimal,
            onChanged: (v) => _chatOptions.repeatPenalty = v ?? 1.1,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.tailFreeSampling,
            labelText: 'Tail Free Sampling',
            infoText:
                'Controls tail-free sampling to reduce the impact of less probable tokens. 1.0 disables this setting; higher values reduce the impact more.',
            type: _BottomSheetTextFieldType.decimal,
            onChanged: (v) => _chatOptions.tailFreeSampling = v ?? 1.0,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.topK,
            labelText: 'Top K',
            infoText:
                'Limits the probability of generating nonsense. A higher value (e.g., 100) allows more diverse answers, while a lower value (e.g., 10) is more conservative.',
            type: _BottomSheetTextFieldType.number,
            onChanged: (v) => _chatOptions.topK = v ?? 40,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.topP,
            labelText: 'Top P',
            infoText:
                'Works with Top K to control text diversity. Higher values lead to more diverse text, lower values to more focused text.',
            type: _BottomSheetTextFieldType.decimalBetween0And1,
            onChanged: (v) => _chatOptions.topP = v ?? 0.9,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.minP,
            labelText: 'Min P',
            infoText:
                'Ensures a balance of quality and variety by setting a minimum token probability relative to the most likely token. Tokens with lower probability are filtered out.',
            type: _BottomSheetTextFieldType.decimalBetween0And1,
            onChanged: (v) => _chatOptions.minP = v ?? 0.0,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.mirostat,
            labelText: 'Mirostat',
            infoText:
                'Enable Mirostat sampling for controlling perplexity. (default: 0, 0 = disabled, 1 = Mirostat, 2 = Mirostat 2.0)',
            type: _BottomSheetTextFieldType.number,
            onChanged: (v) => _chatOptions.mirostat = v ?? 0,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.mirostatEta,
            labelText: 'Mirostat Eta',
            infoText:
                'Influences how quickly the algorithm responds to feedback from the generated text. A lower value results in slower adjustments; a higher value makes the algorithm more responsive.',
            type: _BottomSheetTextFieldType.decimalBetween0And1,
            onChanged: (v) => _chatOptions.mirostatEta = v ?? 0.1,
          ),
          const SizedBox(height: 16),
          _BottomSheetTextField(
            initialValue: _chatOptions.mirostatTau,
            labelText: 'Mirostat Tau',
            infoText:
                'Controls the balance between coherence and diversity of the output. A lower value results in more focused and coherent text. A higher value results in more diverse text.',
            type: _BottomSheetTextFieldType.decimal,
            onChanged: (v) => _chatOptions.mirostatTau = v ?? 5.0,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.info_outline_rounded),
              const SizedBox(width: 8),
              FlexibleText('Leave empty to use the default value'),
            ],
          ),
          TextButton.icon(
            label: const Text('Reset to Defaults'),
            icon: const Icon(Icons.settings_backup_restore_rounded),
            style: TextButton.styleFrom(
              foregroundColor: Colors.red,
              iconColor: Colors.red,
              iconSize: 24,
            ),
            onPressed: () {
              setState(() {
                final defaults = ChatConfigureArguments.defaultArguments;
                widget.arguments.systemPrompt = defaults.systemPrompt;
                widget.arguments.chatOptions = defaults.chatOptions;
              });

              Navigator.of(context).pop();
            },
          ),
        ],
      ],
    );
  }
}

class _RenameButton extends StatelessWidget {
  const _RenameButton({super.key});

  @override
  Widget build(BuildContext context) {
    return _BottomSheetButton(
      icon: const Icon(Icons.edit_outlined),
      title: 'Rename',
      onPressed: () async {
        final chatProvider = Provider.of<ChatProvider>(context, listen: false);

        final newTitle = await _showRenameDialog(
          context,
          currentTitle: chatProvider.currentChat?.title,
        );

        if (newTitle != null) {
          await chatProvider.updateCurrentChat(newTitle: newTitle);
        }
      },
      isDisabled: Provider.of<ChatProvider>(context, listen: false).currentChat == null,
    );
  }

  Future<String?> _showRenameDialog(
    BuildContext context, {
    String? currentTitle,
  }) async {
    String? newTitle;

    return await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename Chat'),
          content: TextFormField(
              initialValue: currentTitle,
              decoration: const InputDecoration(
                labelText: 'New Name',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
              onChanged: (value) => newTitle = value,
              onTapOutside: (PointerDownEvent event) {
                FocusManager.instance.primaryFocus?.unfocus();
              }),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (newTitle != null && newTitle!.trim().isNotEmpty) {
                  Navigator.of(context).pop(newTitle!.trim());
                }
              },
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );
  }
}

/// Per-chat export button — opens a format picker, then hands the produced
/// file to the platform share sheet so the user can save it anywhere.
class _ExportButton extends StatelessWidget {
  const _ExportButton({super.key});

  @override
  Widget build(BuildContext context) {
    final chatProvider = context.watch<ChatProvider>();
    final canExport = chatProvider.currentChat != null &&
        chatProvider.messages.isNotEmpty;

    return _BottomSheetButton(
      icon: const Icon(Icons.ios_share_outlined),
      title: 'Export',
      isDisabled: !canExport,
      onPressed: () async {
        final format = await _pickFormat(context);
        if (format == null || !context.mounted) return;
        await _runExport(context, format);
      },
    );
  }

  Future<ChatExportFormat?> _pickFormat(BuildContext context) {
    return showModalBottomSheet<ChatExportFormat>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Markdown (.md)'),
              subtitle: const Text('Renders nicely in any Markdown viewer.'),
              onTap: () =>
                  Navigator.of(context).pop(ChatExportFormat.markdown),
            ),
            ListTile(
              leading: const Icon(Icons.text_snippet_outlined),
              title: const Text('Plain text (.txt)'),
              subtitle: const Text('Pure text, no formatting.'),
              onTap: () => Navigator.of(context).pop(ChatExportFormat.text),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runExport(BuildContext context, ChatExportFormat format) async {
    final viewModel = context.read<ChatPageViewModel>();
    final messenger = ScaffoldMessenger.of(context);
    final content = await viewModel.exportCurrentChat(format);
    if (content == null) return;

    final filename = viewModel.exportFilename(format);
    try {
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$filename');
      await file.writeAsString(content);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: format.mimeType, name: filename)],
          subject: filename,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }
}

class _DeleteButton extends StatelessWidget {
  const _DeleteButton({super.key});

  @override
  Widget build(BuildContext context) {
    return _BottomSheetButton(
      icon: const Icon(Icons.delete_outline),
      title: 'Delete',
      onPressed: () {
        _showDeleteDialog(context);
      },
      isDestructive: true,
      isDisabled: Provider.of<ChatProvider>(context, listen: false).currentChat == null,
    );
  }

  void _showDeleteDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete Chat?'),
          content: const Text(
            'This action can\'t be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Provider.of<ChatProvider>(context, listen: false).deleteCurrentChat();

                Navigator.of(context)
                  ..pop()
                  ..pop(ChatConfigureBottomSheetAction.delete);
              },
              style: TextButton.styleFrom(
                foregroundColor: Colors.red,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }
}

class _BottomSheetButton extends StatelessWidget {
  final Icon icon;
  final String title;
  final VoidCallback? onPressed;
  final bool isDisabled;
  final bool isDestructive;

  const _BottomSheetButton({
    required this.icon,
    required this.title,
    required this.onPressed,
    this.isDisabled = false,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: isDisabled ? null : onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        foregroundColor: isDestructive ? Colors.red : null,
        iconColor: isDestructive ? Colors.red : null,
        iconSize: 24,
        padding: const EdgeInsets.all(16.0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8.0),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          FlexibleText(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _BottomSheetTextField<T> extends StatefulWidget {
  final T? initialValue;

  final String labelText;
  final String infoText;
  final _BottomSheetTextFieldType type;

  final Function(T?)? onChanged;

  const _BottomSheetTextField({
    super.key,
    this.initialValue,
    required this.labelText,
    required this.infoText,
    required this.type,
    this.onChanged,
  });

  @override
  State<_BottomSheetTextField<T>> createState() => _BottomSheetTextFieldState();
}

class _BottomSheetTextFieldState<T> extends State<_BottomSheetTextField<T>> {
  String? _errorText;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      initialValue: widget.initialValue?.toString(),
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: _hintText,
        errorText: _errorText,
        border: OutlineInputBorder(),
        suffixIcon: IconButton(
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) {
                return AlertDialog(
                  title: Text(widget.labelText),
                  content: Text(widget.infoText),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                );
              },
            );
          },
          icon: Icon(Icons.info_outline),
        ),
      ),
      onChanged: (value) {
        final (validValue, errorText) = _validator(value);
        setState(() => _errorText = errorText);

        widget.onChanged?.call(validValue);
      },
      keyboardType: _keyboardType,
      textCapitalization: TextCapitalization.sentences,
      onTapOutside: (PointerDownEvent event) {
        FocusManager.instance.primaryFocus?.unfocus();
      },
    );
  }

  String get _hintText {
    switch (widget.type) {
      case _BottomSheetTextFieldType.text:
        return 'Enter a text';
      case _BottomSheetTextFieldType.number:
        return 'Enter a number';
      case _BottomSheetTextFieldType.decimal:
        return 'Enter a value';
      case _BottomSheetTextFieldType.decimalBetween0And1:
        return 'Enter a value between 0 and 1';
    }
  }

  (T?, String?) Function(String?) get _validator {
    switch (widget.type) {
      case _BottomSheetTextFieldType.text:
        return (v) {
          if (v == null) {
            return (null, '${widget.labelText} must not be empty');
          } else if (v.isEmpty) {
            return (null, null);
          } else {
            return (v as T?, null);
          }
        };
      case _BottomSheetTextFieldType.number:
        return (v) {
          if (v == null) {
            return (null, '${widget.labelText} must not be empty');
          } else if (v.isEmpty) {
            return (null, null);
          } else if (int.tryParse(v) == null) {
            return (null, '${widget.labelText} must be a number');
          } else {
            return (int.tryParse(v) as T?, null);
          }
        };
      case _BottomSheetTextFieldType.decimal:
        return (value) {
          final v = value?.replaceAll(',', '.');

          if (v == null) {
            return (null, '${widget.labelText} must not be empty');
          } else if (v.isEmpty) {
            return (null, null);
          } else if (double.tryParse(v) == null) {
            return (null, '${widget.labelText} must be a decimal number');
          } else {
            return (double.tryParse(v) as T?, null);
          }
        };
      case _BottomSheetTextFieldType.decimalBetween0And1:
        return (value) {
          final v = value?.replaceAll(',', '.');

          if (v == null) {
            return (null, '${widget.labelText} must not be empty');
          } else if (v.isEmpty) {
            return (null, null);
          } else if (double.tryParse(v) == null) {
            return (null, '${widget.labelText} must be a decimal number');
          } else {
            final value = double.parse(v);
            if (value < 0 || value > 1) {
              return (null, '${widget.labelText} must be between 0 and 1');
            } else {
              return (double.tryParse(v) as T?, null);
            }
          }
        };
    }
  }

  TextInputType get _keyboardType {
    switch (widget.type) {
      case _BottomSheetTextFieldType.text:
        return TextInputType.text;
      case _BottomSheetTextFieldType.number:
        return TextInputType.number;
      case _BottomSheetTextFieldType.decimal:
        return TextInputType.numberWithOptions(decimal: true);
      case _BottomSheetTextFieldType.decimalBetween0And1:
        return TextInputType.numberWithOptions(decimal: true);
    }
  }
}

enum _BottomSheetTextFieldType {
  text,
  number,
  decimal,
  decimalBetween0And1,
}

enum ChatConfigureBottomSheetAction {
  delete,
}

/// Per-chat web-search toggle. When on, each prompt is enriched with live
/// search results before being sent to the model — works for every provider.
/// The subtitle nudges the user to Settings when no backend is configured yet.
class _WebSearchTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _WebSearchTile({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = context.read<WebSearchService>().isConfigured;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: SwitchListTile(
        // Without a configured backend the feature is a silent no-op, so don't
        // let the switch read "on" — disable it and point the user at Settings.
        value: configured && value,
        onChanged: configured ? onChanged : null,
        secondary: const Icon(Icons.travel_explore_outlined),
        title: const Text('Web search'),
        subtitle: Text(
          configured
              ? 'Let the model search the web when a question needs current info, with cited sources.'
              : 'Set up a search backend in Settings to enable this.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12.0),
      ),
    );
  }
}

/// Per-chat artifacts toggle. When on, the model is asked (via a system-prompt
/// addon) to wrap substantial standalone deliverables in `<artifact>` tags,
/// which render as a card + dedicated viewer. Works for every provider.
class _ArtifactsTile extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ArtifactsTile({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        secondary: const Icon(Icons.dashboard_customize_outlined),
        title: const Text('Artifacts'),
        subtitle: Text(
          'Render full documents and code files as a card you can open, copy, '
          'and export. Short snippets stay inline.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12.0),
      ),
    );
  }
}

/// Tri-state toggle for the Ollama API's `think` field. Null = don't send,
/// let the model use its default. True = force thinking on. False = force
/// thinking off. Ollama models without a thinking phase ignore the field.
class _ThinkingModeTile extends StatelessWidget {
  final bool? value;
  final ValueChanged<bool?> onChanged;

  const _ThinkingModeTile({required this.value, required this.onChanged});

  String _label(bool? v) {
    switch (v) {
      case true:
        return 'Force on';
      case false:
        return 'Force off (no_think)';
      default:
        return "Model default";
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(
            'Thinking',
            style: theme.textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(
            'Ollama-only. For models that support a thinking phase (Qwen 3, gpt-oss, etc.). Other models ignore this.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 0, label: Text('Default'), icon: Icon(Icons.auto_awesome_outlined)),
            ButtonSegment(value: 1, label: Text('On'), icon: Icon(Icons.lightbulb_outline)),
            ButtonSegment(value: 2, label: Text('Off'), icon: Icon(Icons.flash_off_outlined)),
          ],
          selected: {
            value == null ? 0 : (value == true ? 1 : 2),
          },
          onSelectionChanged: (s) {
            final v = s.first;
            onChanged(v == 0 ? null : (v == 1 ? true : false));
          },
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(
            'Current: ${_label(value)}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
