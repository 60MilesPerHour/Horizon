import 'package:flutter/material.dart';
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/appearance_controller.dart';
import 'package:horizon/Widgets/frosted_surface.dart';
import 'package:provider/provider.dart';
import 'package:responsive_framework/responsive_framework.dart';

import 'title_divider.dart';

class ChatDrawer extends StatelessWidget {
  const ChatDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final frosted = context.watch<AppearanceController>().appearance.isFrosted;

    return Drawer(
      // The Drawer paints its own background, so a translucent one from the
      // theme would still sit on top of the blur. Transparent here; tint and
      // blur both come from FrostedSurface.
      backgroundColor: frosted ? Colors.transparent : null,
      child: FrostedSurface(
        child: SafeArea(
          child: Column(
            children: [
              const Expanded(child: ChatNavigationDrawer()),
              Container(
                alignment: Alignment.centerLeft,
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
                      icon: const Icon(Icons.graphic_eq),
                      tooltip: 'Voice mode',
                      onPressed: () {
                        if (ResponsiveBreakpoints.of(context).isMobile) {
                          Navigator.pop(context);
                        }
                        Navigator.pushNamed(context, '/assistant');
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
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
              // Voice mode's chat is long-lived and shared with the assist
              // gesture, so it gets its own icon — it isn't a conversation you
              // started and it shouldn't look like one. Order is deliberately
              // left alone: the drawer's selection is index-based against this
              // same list, and reordering here would select the wrong chat.
              final isAssistant = chatProvider.isAssistantChat(chat);
              return NavigationDrawerDestination(
                icon: Icon(
                  isAssistant ? Icons.graphic_eq : Icons.chat_outlined,
                ),
                label: Expanded(
                  child: Text(
                    chat.title,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                selectedIcon: Icon(isAssistant ? Icons.graphic_eq : Icons.chat),
              );
            }),
          ],
        );
      },
    );
  }
}
