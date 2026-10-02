import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Widgets/chat_configure_bottom_sheet.dart';
import 'package:horizon/Widgets/frosted_surface.dart';
import 'package:horizon/Widgets/ollama_health_indicator.dart';
import 'package:provider/provider.dart';
import 'package:responsive_framework/responsive_framework.dart';

class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({super.key});

  @override
  Widget build(BuildContext context) {
    final chatProvider = Provider.of<ChatProvider>(context);
    final chat = chatProvider.currentChat;
    final inConversation = chat != null && chatProvider.messages.isNotEmpty;
    final theme = Theme.of(context);

    return AppBar(
      // Paints the blur *behind* the bar's own contents; a BackdropFilter
      // only blurs what's already been painted under it, and the bar's
      // background is transparent under the frosted style (see HorizonTheme).
      flexibleSpace: const FrostedSurface(),
      // The wordmark always; in a conversation, the conversation's name sits
      // quietly beneath it. The model lives in the composer now.
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(AppConstants.appName, style: GoogleFonts.pacifico(fontSize: inConversation ? 20 : 22)),
          if (inConversation)
            Text(
              chat.title,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: .2,
              ),
            ),
        ],
      ),
      actions: [
        // Show Ollama health only when the current chat actually uses it —
        // otherwise the dot is noise for cloud-only users.
        if (chat?.provider == 'ollama' || chat == null) const OllamaHealthIndicator(),
        // A branch is otherwise indistinguishable from a duplicate in the
        // sidebar, so give it a visible way back to what it came from.
        if (chat?.isBranch == true)
          IconButton(
            icon: const Icon(Icons.call_split),
            tooltip: 'Go to the chat this was branched from',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              final opened = await chatProvider.openParentOf(chat!);
              if (!opened) {
                messenger.showSnackBar(const SnackBar(
                  content: Text('The original chat has been deleted.'),
                ));
              }
            },
          ),
        MenuAnchor(
          menuChildren: [
            if (chat != null)
              MenuItemButton(
                leadingIcon: const Icon(Icons.tune),
                onPressed: () => _handleConfigureButton(context),
                child: const Text('Chat settings'),
              ),
            MenuItemButton(
              leadingIcon: const Icon(Icons.file_upload_outlined),
              onPressed: () => _handleImport(context),
              child: const Text('Import a chat'),
            ),
          ],
          builder: (context, controller, _) => IconButton(
            icon: const Icon(Icons.more_horiz),
            tooltip: 'More',
            onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
      ],
      forceMaterialTransparency: !ResponsiveBreakpoints.of(context).isMobile,
    );
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

    // FileType.any, not custom: Android's picker filters by MIME type and has
    // none for `.reins`, so a custom filter would grey those files out.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    const importable = ['md', 'txt', 'markdown', 'reins'];
    if (!importable.contains(file.extension?.toLowerCase())) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Pick a .md, .txt or .reins chat export.'),
        ),
      );
      return;
    }
    Uint8List bytes;
    try {
      if (file.bytes != null) {
        bytes = file.bytes!;
      } else if (file.path != null) {
        bytes = await File(file.path!).readAsBytes();
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
      final chat = await chatProvider.importChatFromBytes(bytes);
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
