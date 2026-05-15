import 'package:flutter/material.dart';
import 'package:horizon/Pages/chat_page/chat_page.dart';
import 'package:horizon/Widgets/chat_app_bar.dart';
import 'package:horizon/Widgets/chat_drawer.dart';
import 'package:responsive_framework/responsive_framework.dart';

class HorizonMainPage extends StatelessWidget {
  const HorizonMainPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (ResponsiveBreakpoints.of(context).isMobile) {
      return _HorizonMobileMainPage();
    } else {
      return _HorizonLargeMainPage();
    }
  }
}

class _HorizonMobileMainPage extends StatelessWidget {
  const _HorizonMobileMainPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      appBar: ChatAppBar(),
      body: SafeArea(child: ChatPage()),
      drawer: ChatDrawer(),
    );
  }
}

class _HorizonLargeMainPage extends StatelessWidget {
  const _HorizonLargeMainPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            ChatDrawer(),
            Expanded(child: ChatPage()),
          ],
        ),
      ),
    );
  }
}
