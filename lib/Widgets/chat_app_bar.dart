import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Pages/chat_page/chat_page_view_model.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/chat_export_service.dart';
import 'package:horizon/Widgets/chat_configure_bottom_sheet.dart';
import 'package:horizon/Widgets/model_selection_bottom_sheet.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:share_plus/share_plus.dart';

class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({super.key});

  @override
  Widget build(BuildContext context) {
    final chatProvider = Provider.of<ChatProvider>(context);

    return AppBar(
      title: Column(
        children: [
          Text(AppConstants.appName, style: GoogleFonts.pacifico()),
          if (chatProvider.currentChat != null)
            InkWell(
              onTap: () {
                _handleModelSelectionButton(context);
              },
              customBorder: StadiumBorder(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  chatProvider.currentChat!.model,
                  style: GoogleFonts.kodeMono(
                    textStyle: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        // Export-current-chat menu. Only enabled when there's a chat with
        // messages — see ChatPageViewModel.canExportCurrentChat.
        PopupMenuButton<_AppBarAction>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'Chat actions',
          onSelected: (action) => _handleAppBarAction(context, action),
          itemBuilder: (context) {
            final canExport =
                context.read<ChatProvider>().currentChat != null &&
                    context.read<ChatProvider>().messages.isNotEmpty;
            return [
              PopupMenuItem(
                value: _AppBarAction.exportMarkdown,
                enabled: canExport,
                child: const ListTile(
                  leading: Icon(Icons.description_outlined),
                  title: Text('Export as Markdown'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: _AppBarAction.exportText,
                enabled: canExport,
                child: const ListTile(
                  leading: Icon(Icons.text_snippet_outlined),
                  title: Text('Export as text'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ];
          },
        ),
        IconButton(
          icon: const Icon(Icons.tune),
          onPressed: () {
            _handleConfigureButton(context);
          },
        ),
      ],
      forceMaterialTransparency: !ResponsiveBreakpoints.of(context).isMobile,
    );
  }

  Future<void> _handleModelSelectionButton(BuildContext context) async {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    final selectedModel = await showModelSelectionBottomSheet(
      context: context,
      title: "Change The Model",
      currentModelName: chatProvider.currentChat?.model,
    );

    if (selectedModel != null) {
      await chatProvider.updateCurrentChat(
        newModel: selectedModel.name,
        newProvider: selectedModel.provider,
      );
    }
  }

  Future<void> _handleConfigureButton(BuildContext context) async {
    final chatProvider = Provider.of<ChatProvider>(context, listen: false);

    final arguments = chatProvider.currentChatConfiguration;

    final ChatConfigureBottomSheetAction? action = await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: ChatConfigureBottomSheet(arguments: arguments),
        );
      },
    );

    // If the user deletes the chat, we don't need to update the chat.
    if (action == ChatConfigureBottomSheetAction.delete) return;

    await chatProvider.updateCurrentChat(
      newSystemPrompt: arguments.systemPrompt,
      newOptions: arguments.chatOptions,
    );
  }

  Future<void> _handleAppBarAction(
    BuildContext context,
    _AppBarAction action,
  ) async {
    final format = switch (action) {
      _AppBarAction.exportMarkdown => ChatExportFormat.markdown,
      _AppBarAction.exportText => ChatExportFormat.text,
    };

    final viewModel = context.read<ChatPageViewModel>();
    if (!viewModel.canExportCurrentChat) return;

    final content = await viewModel.exportCurrentChat(format);
    if (content == null || !context.mounted) return;

    final filename = viewModel.exportFilename(format);

    // Write to a temp file and hand it to the platform share sheet — that
    // covers "save to Downloads", "send via messenger", "open with editor",
    // etc. without us having to ask for storage permissions ourselves.
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
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

enum _AppBarAction { exportMarkdown, exportText }
