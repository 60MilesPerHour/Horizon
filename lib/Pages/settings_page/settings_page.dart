import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:horizon/Models/settings_route_arguments.dart';

import 'package:horizon/Pages/settings_page/settings_category_page.dart';
import 'package:horizon/Pages/settings_page/voice_settings_page.dart';

import 'subwidgets/subwidgets.dart';

class SettingsPage extends StatelessWidget {
  final SettingsRouteArguments? arguments;

  const SettingsPage({super.key, this.arguments});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings', style: GoogleFonts.pacifico()),
      ),
      body: SafeArea(
        child: _SettingsPageContent(arguments: arguments),
      ),
    );
  }
}

class _SettingsPageContent extends StatelessWidget {
  final SettingsRouteArguments? arguments;

  const _SettingsPageContent({required this.arguments});

  @override
  Widget build(BuildContext context) {
    // Deep link from "tap to configure server address": jump straight into
    // the server category rather than dropping the user on an index and
    // making them find it.
    if (arguments?.autoFocusServerAddress == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const SettingsCategoryPage(
            title: 'Ollama Server',
            children: [ServerSettings(autoFocusServerAddress: true)],
          ),
        ));
      });
    }

    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: const [
        SettingsCategoryTile(
          icon: Icons.dns_outlined,
          title: 'Ollama Server',
          subtitle: 'Address, backup server, network scan, Cloudflare Access',
          pageBuilder: _serverPage,
        ),
        SettingsCategoryTile(
          icon: Icons.cloud_outlined,
          title: 'Cloud Models',
          subtitle: 'OpenRouter, and direct Anthropic / OpenAI / Google keys',
          pageBuilder: _cloudPage,
        ),
        SettingsCategoryTile(
          icon: Icons.handyman_outlined,
          title: 'Tools & Web Search',
          subtitle: 'Search backend for the web_search and web_fetch tools',
          pageBuilder: _toolsPage,
        ),
        SettingsCategoryTile(
          icon: Icons.graphic_eq,
          title: 'Voice',
          subtitle: 'Assistant model, speech recognition, and the voice that '
              'reads replies',
          pageBuilder: _voicePage,
        ),
        SettingsCategoryTile(
          icon: Icons.palette_outlined,
          title: 'Appearance',
          subtitle: 'Theme and accent colour',
          pageBuilder: _appearancePage,
        ),
        SettingsCategoryTile(
          icon: Icons.settings_backup_restore,
          title: 'Backup & Restore',
          subtitle: 'Export or import your settings and API keys',
          pageBuilder: _backupPage,
        ),
        SettingsCategoryTile(
          icon: Icons.info_outline,
          title: 'About Horizon',
          subtitle: 'Version, licences, and links',
          pageBuilder: _aboutPage,
        ),
      ],
    );
  }
}

// Top-level so the tiles above can be `const`, which keeps the whole root
// list from rebuilding when anything in a category changes.
Widget _serverPage(BuildContext context) => const SettingsCategoryPage(
      title: 'Ollama Server',
      children: [ServerSettings(autoFocusServerAddress: false)],
    );

Widget _cloudPage(BuildContext context) => const SettingsCategoryPage(
      title: 'Cloud Models',
      children: [CloudProviderSettings()],
    );

Widget _toolsPage(BuildContext context) => const SettingsCategoryPage(
      title: 'Tools & Web Search',
      children: [WebSearchSettings()],
    );

Widget _voicePage(BuildContext context) => const VoiceSettingsPage();

Widget _appearancePage(BuildContext context) => const SettingsCategoryPage(
      title: 'Appearance',
      children: [ThemesSettings()],
    );

Widget _backupPage(BuildContext context) => const SettingsCategoryPage(
      title: 'Backup & Restore',
      children: [ConfigBackupSettings()],
    );

Widget _aboutPage(BuildContext context) => const SettingsCategoryPage(
      title: 'About Horizon',
      children: [HorizonSettings()],
    );
