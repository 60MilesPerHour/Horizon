import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Widgets/chat_configure_bottom_sheet.dart';
import 'package:horizon/Widgets/frosted_surface.dart';
import 'package:horizon/Widgets/model_selection_bottom_sheet.dart';
import 'package:horizon/Widgets/ollama_health_indicator.dart';
import 'package:provider/provider.dart';
import 'package:responsive_framework/responsive_framework.dart';

class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({super.key});

  @override
  Widget build(BuildContext context) {
    final chatProvider = Provider.of<ChatProvider>(context);

    return AppBar(
      // Paints the blur *behind* the bar's own contents; a BackdropFilter
      // only blurs what's already been painted under it, and the bar's
      // background is transparent under the frosted style (see HorizonTheme).
      flexibleSpace: const FrostedSurface(),
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
        // Show Ollama health only when the current chat actually uses it —
        // otherwise the dot is noise for cloud-only users.
        if (chatProvider.currentChat?.provider == 'ollama' || chatProvider.currentChat == null)
          const OllamaHealthIndicator(),
        // A branch is otherwise indistinguishable from a duplicate in the
        // sidebar, so give it a visible way back to what it came from.
        if (chatProvider.currentChat?.isBranch == true)
          IconButton(
            icon: const Icon(Icons.call_split),
            tooltip: 'Go to the chat this was branched from',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final opened =
                  await chatProvider.openParentOf(chatProvider.currentChat!);
              if (!opened) {
                messenger.showSnackBar(const SnackBar(
                  content: Text('The original chat has been deleted.'),
                ));
              }
            },
          ),
        IconButton(
          icon: const Icon(Icons.file_upload_outlined),
          tooltip: 'Import chat from file',
          onPressed: () => _handleImport(context),
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

  Future<void> _handleImport(BuildContext context) async {
    final chatProvider = context.read<ChatProvider>();
    final messenger = ScaffoldMessenger.of(context);

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['md', 'txt', 'markdown'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    String content;
    try {
      // utf8.decode, NOT String.fromCharCodes — the message-header separator
      // is U+00B7 ('·') which is two bytes in UTF-8; the broken decode used
      // to drop messages entirely on import.
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not read the selected file.')),
        );
        return;
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not read the file: $e')),
      );
      return;
    }

    try {
      final chat = await chatProvider.importChatFromString(content);
      messenger.showSnackBar(
        SnackBar(content: Text('Imported "${chat.title}"')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
