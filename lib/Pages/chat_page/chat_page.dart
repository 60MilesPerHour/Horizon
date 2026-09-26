import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:responsive_framework/responsive_framework.dart';

import 'package:horizon/Pages/chat_page/subwidgets/chat_bubble/chat_bubble_attachment.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Widgets/chat_app_bar.dart';
import 'package:horizon/Widgets/horizon_brand.dart';
import 'package:horizon/Models/settings_route_arguments.dart';
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

  @override
  void initState() {
    super.initState();
    _viewModel = context.read<ChatPageViewModel>();
  }

  @override
  Widget build(BuildContext context) {
    // Subscribe to ViewModel changes
    context.watch<ChatPageViewModel>();
    final vm = _viewModel;

    return Column(
      children: <Widget>[
        if (!ResponsiveBreakpoints.of(context).isMobile) ChatAppBar(), // If the screen is large, show the app bar
        // The horizon under the bar, once there's a conversation to sit over.
        if (vm.messages.isNotEmpty) const HorizonLine(horizontalPadding: 20),
        Expanded(
          child: Stack(
            alignment: Alignment.bottomLeft,
            children: [
              _buildChatBody(),
              _buildChatFooter(),
            ],
          ),
        ),
        HorizonComposer(
          key: ValueKey(vm.currentChat?.id),
          controller: vm.textFieldController,
          hint: vm.messages.isEmpty ? 'Ask anything' : 'Reply',
          modelLabel: vm.currentChat?.model ?? vm.selectedModel?.name,
          onModelTap: _changeModel,
          attachButton: MenuAnchor(
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
              visualDensity: VisualDensity.compact,
              tooltip: 'Attach',
              onPressed: () => controller.isOpen ? controller.close() : controller.open(),
            ),
          ),
          canSend: vm.hasText || vm.hasStagedFiles,
          streaming: vm.isStreaming,
          onSend: _sendMessage,
          onStop: vm.cancelStreaming,
          onVoice: () => Navigator.pushNamed(context, '/assistant'),
        ),
      ],
    );
  }

  Widget _buildChatBody() {
    if (_viewModel.messages.isEmpty) {
      return HorizonHome(
        suggestions: _viewModel.presets,
        onSuggestion: (preset) async {
          _viewModel.setTextFieldValue(preset.prompt);
          await _sendMessage();
        },
        notice: _viewModel.isServerConfigured
            ? null
            : Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: Icon(Icons.dns_outlined, color: HorizonBrand.accent(context)),
                  label: const Text('Connect a server to begin'),
                  onPressed: () => Navigator.pushNamed(context, '/settings', arguments: SettingsRouteArguments(autoFocusServerAddress: true)),
                ),
              ),
      );
    }
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
          : null,
    );
  }

  /// Staged attachments, in one row over the composer. (Suggestions used to
  /// live here as a row of cards; they're part of the home screen now.)
  Widget _buildChatFooter() {
    if (!_viewModel.hasStagedFiles) return const SizedBox();
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
  }

  /// The model shown in the composer. Changing it inside a chat repins that
  /// chat; before the first message it picks the model the chat will start on.
  Future<void> _changeModel() async {
    final chatProvider = context.read<ChatProvider>();
    final chat = _viewModel.currentChat;
    final selected = await showModelSelectionBottomSheet(
      context: context,
      title: 'Choose a model',
      currentModelName: chat?.model ?? _viewModel.selectedModel?.name,
    );
    if (selected == null) return;
    if (chat == null) {
      _viewModel.setSelectedModel(selected);
    } else {
      await chatProvider.updateCurrentChat(newModel: selected.name, newProvider: selected.provider);
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
      title: 'Choose a model',
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
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Connect a server in Settings first.')),
    );
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
