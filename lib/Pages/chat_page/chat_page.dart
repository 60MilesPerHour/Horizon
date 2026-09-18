import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:responsive_framework/responsive_framework.dart';

import 'package:horizon/Pages/chat_page/subwidgets/chat_bubble/chat_bubble_attachment.dart';
import 'package:horizon/Widgets/chat_app_bar.dart';
import 'package:horizon/Widgets/model_selection_bottom_sheet.dart';

import 'chat_page_view_model.dart';
import 'subwidgets/subwidgets.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  // ViewModel reference
  late final ChatPageViewModel _viewModel;

  // Welcome screen animation state
  var _crossFadeState = CrossFadeState.showFirst;
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    _viewModel = context.read<ChatPageViewModel>();
  }

  @override
  Widget build(BuildContext context) {
    // Subscribe to ViewModel changes
    context.watch<ChatPageViewModel>();

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (!ResponsiveBreakpoints.of(context).isMobile) ChatAppBar(), // If the screen is large, show the app bar
        Expanded(
          child: Stack(
            alignment: Alignment.bottomLeft,
            children: [
              _buildChatBody(),
              _buildChatFooter(),
            ],
          ),
        ),
        // TODO: Wrap with ConstrainedBox to limit the height
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ChatTextField(
            key: ValueKey(_viewModel.currentChat?.id),
            controller: _viewModel.textFieldController,
            onEditingComplete: _sendMessage,
            prefixIcon: MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.image_outlined),
                  onPressed: _pickImages,
                  child: const Text('Photo'),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.attach_file),
                  onPressed: _pickDocuments,
                  child: const Text('Document'),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                icon: const Icon(Icons.add),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
              ),
            ),
            suffixIcon: _buildTextFieldSuffixIcon(),
          ),
        ),
      ],
    );
  }

  Widget _buildChatBody() {
    if (_viewModel.messages.isEmpty) {
      if (_viewModel.currentChat == null) {
        if (!_viewModel.isServerConfigured) {
          return ChatEmpty(
            child: ChatWelcome(
              showingState: _crossFadeState,
              onFirstChildFinished: () => setState(() => _crossFadeState = CrossFadeState.showSecond),
              secondChildScale: _scale,
              onSecondChildScaleEnd: () => setState(() => _scale = 1.0),
            ),
          );
        } else {
          return ChatEmpty(
            child: ChatSelectModelButton(
              currentModelName: _viewModel.selectedModel?.name,
              onPressed: _showModelSelectionBottomSheet,
            ),
          );
        }
      } else {
        return ChatEmpty(
          child: Text('No messages yet!'),
        );
      }
    } else {
      return ChatListView(
        key: PageStorageKey<String>(_viewModel.currentChat?.id ?? 'empty'),
        messages: _viewModel.messages,
        isAwaitingReply: _viewModel.isThinking,
        statusLabel: _viewModel.activityLabel ?? 'Generating',
        streamingContent: _viewModel.isStreaming ? _viewModel.streamingContent : null,
        error: _viewModel.currentError != null
            ? ChatError(
                message: _viewModel.currentError!.message,
                onRetry: () => _viewModel.retryLastPrompt(),
              )
            : null,
        bottomPadding: _viewModel.hasStagedFiles
            ? MediaQuery.of(context).size.height * 0.15
            : null, // TODO: Calculate the height of attachments row
      );
    }
  }

  Widget _buildChatFooter() {
    if (_viewModel.hasStagedFiles) {
      // Images and documents share one row so attaching both doesn't stack
      // two scrollers over the prompt field. Images come first because their
      // thumbnails are the taller item and set the row height.
      final images = _viewModel.imageFiles;
      final documents = _viewModel.attachments;
      return ChatAttachmentRow(
        itemCount: images.length + documents.length,
        itemBuilder: (context, index) {
          if (index < images.length) {
            return ChatAttachmentImage(
              imageFile: images[index],
              onRemove: (imageFile) => _viewModel.removeImage(imageFile),
            );
          }
          final attachment = documents[index - images.length];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4.0),
            child: AttachmentChip(
              attachment: attachment,
              onRemove: () => _viewModel.removeAttachment(attachment),
            ),
          );
        },
      );
    } else if (_viewModel.messages.isEmpty) {
      return ChatAttachmentRow(
        itemCount: _viewModel.presets.length,
        itemBuilder: (context, index) {
          final preset = _viewModel.presets[index];
          return ChatAttachmentPreset(
            preset: preset,
            onPressed: () async {
              _viewModel.setTextFieldValue(preset.prompt);
              await _sendMessage();
            },
          );
        },
      );
    } else {
      return const SizedBox();
    }
  }

  Widget? _buildTextFieldSuffixIcon() {
    if (_viewModel.isStreaming) {
      return IconButton(
        icon: const Icon(Icons.stop_rounded),
        color: Theme.of(context).colorScheme.onSurface,
        onPressed: _viewModel.cancelStreaming,
      );
    } else if (_viewModel.hasText || _viewModel.hasStagedFiles) {
      return IconButton(
        icon: const Icon(Icons.arrow_upward_rounded),
        color: Theme.of(context).colorScheme.onSurface,
        onPressed: _sendMessage,
      );
    } else {
      return null;
    }
  }

  Future<void> _sendMessage() async {
    await _viewModel.sendMessage(
      onModelSelectionRequired: _showModelSelectionBottomSheet,
      onServerNotConfigured: _onServerNotConfigured,
    );
  }

  Future<void> _showModelSelectionBottomSheet() async {
    final selectedModel = await showModelSelectionBottomSheet(
      context: context,
      title: "Select a Model",
      currentModelName: _viewModel.selectedModel?.name,
    );

    if (selectedModel != null) {
      _viewModel.setSelectedModel(selectedModel);
    }
  }

  Future<void> _pickImages() async {
    await _viewModel.pickImages(
      onPermissionDenied: _showPhotosDeniedAlert,
    );
  }

  Future<void> _pickDocuments() async {
    await _viewModel.pickAttachments(onError: _showAttachmentError);
  }

  void _showAttachmentError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _onServerNotConfigured() {
    setState(() {
      _crossFadeState = CrossFadeState.showSecond;
      _scale = _scale == 1.0 ? 1.05 : 1.0;
    });
  }

  Future<void> _showPhotosDeniedAlert() async {
    await showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('Photos Permission Denied'),
          content: const Text('Please allow access to photos in the settings.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }
}
