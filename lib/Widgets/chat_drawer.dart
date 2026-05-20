import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:provider/provider.dart';
import 'package:responsive_framework/responsive_framework.dart';

import 'title_divider.dart';

Future<void> _handleImport(BuildContext context) async {
  final chatProvider = context.read<ChatProvider>();
  final messenger = ScaffoldMessenger.of(context);
  // Capture isMobile before any awaits so we know whether to pop the
  // drawer when we're done.
  final isMobile = ResponsiveBreakpoints.of(context).isMobile;

  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['md', 'txt', 'markdown'],
    withData: true,
  );
  if (result == null || result.files.isEmpty) return;

  final file = result.files.single;
  String content;
  try {
    // Decode bytes as UTF-8, NOT String.fromCharCodes — that treats each byte
    // as a code unit and mangles every non-ASCII glyph (most importantly the
    // U+00B7 `·` separators we use in message headers), which made the parser
    // find zero messages and import an empty chat.
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
    if (isMobile && context.mounted) Navigator.of(context).pop();
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Import failed: $e')),
    );
  }
}

class ChatDrawer extends StatelessWidget {
  const ChatDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            const Expanded(child: ChatNavigationDrawer()),
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 10),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: 'Settings',
                    onPressed: () {
                      if (ResponsiveBreakpoints.of(context).isMobile) {
                        Navigator.pop(context);
                      }
                      Navigator.pushNamed(context, '/settings');
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.file_upload_outlined),
                    tooltip: 'Import chat from file',
                    onPressed: () => _handleImport(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatNavigationDrawer extends StatelessWidget {
  const ChatNavigationDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, _) {
        return NavigationDrawer(
          selectedIndex: chatProvider.selectedDestination,
          onDestinationSelected: (destination) {
            chatProvider.destinationChatSelected(destination);

            if (ResponsiveBreakpoints.of(context).isMobile) {
              Navigator.pop(context);
            }
          },
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 16, 16, 10),
              child: Text(
                AppConstants.appName,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const NavigationDrawerDestination(
              icon: CircleAvatar(
                backgroundImage: AssetImage(AppConstants.ollamaIconPng),
                radius: 16,
              ),
              label: Text("Ollama"),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(28, 16, 28, 10),
              child: TitleDivider(title: "Chats"),
            ),
            ...chatProvider.chats.map((chat) {
              return NavigationDrawerDestination(
                icon: const Icon(Icons.chat_outlined),
                label: Expanded(
                  child: Text(
                    chat.title,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                selectedIcon: const Icon(Icons.chat),
              );
            }),
          ],
        );
      },
    );
  }
}
