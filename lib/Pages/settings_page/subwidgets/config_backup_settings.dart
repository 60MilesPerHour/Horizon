import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:horizon/Services/config_backup_service.dart';
import 'package:horizon/Services/ollama_service.dart';
import 'package:horizon/Services/openrouter_service.dart';

/// Export / import of API keys and server settings, so a fresh install (or a
/// second device) can be set up from one file instead of re-typing every key.
class ConfigBackupSettings extends StatelessWidget {
  const ConfigBackupSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Backup & Restore',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'Save your API keys and server settings to a file, then restore them '
          'on a new install. The file contains your keys in plain text — keep it '
          'somewhere private.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.upload_file_outlined),
          title: const Text('Back up configuration'),
          subtitle: const Text('Export keys & server settings to a JSON file'),
          onTap: () => _handleExport(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.download_outlined),
          title: const Text('Restore configuration'),
          subtitle: const Text('Import keys & server settings from a file'),
          onTap: () => _handleImport(context),
        ),
      ],
    );
  }

  Future<void> _handleExport(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final content = await ConfigBackupService().exportToJson();

      const filename = 'horizon-config.json';
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$filename');
      await file.writeAsString(content);

      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(file.path, mimeType: 'application/json', name: filename),
          ],
          subject: filename,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Backup failed: $e')),
      );
    }
  }

  Future<void> _handleImport(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    // Capture the live services before any await so we don't touch a stale
    // context after the file picker / async writes.
    final openrouter = context.read<OpenRouterService>();
    final ollama = context.read<OllamaService>();

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    String content;
    try {
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
      final imported = await ConfigBackupService().importFromJson(content);

      // Push restored secrets into the running services so they take effect
      // immediately, without an app restart.
      final p = imported.providers;
      if (p.containsKey('openrouter_api_key')) {
        final key = p['openrouter_api_key']!;
        openrouter.apiKey = key;
        // The enable flag rides along in the settings block, but a restored
        // key with the switch left off is indistinguishable from a broken
        // restore, so turn it on when there's a key to use.
        if (key.isNotEmpty) openrouter.enabled = true;
      }
      // A backup written by v3.x also carries anthropic/openai/google keys.
      // They're ignored rather than restored: nothing reads them since the
      // direct clients were removed in v4.0.0.
      if (p.containsKey('ollama_api_token')) {
        ollama.apiToken = p['ollama_api_token']!;
      }
      if (p.containsKey('cf_access_client_id')) {
        ollama.cfAccessClientId = p['cf_access_client_id']!;
      }
      if (p.containsKey('cf_access_client_secret')) {
        ollama.cfAccessClientSecret = p['cf_access_client_secret']!;
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(
            imported.isEmpty
                ? 'Nothing to restore — the file had no recognised settings.'
                : 'Restored ${imported.count} setting${imported.count == 1 ? '' : 's'}. '
                    'Reopen Settings to see the updated fields.',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Restore failed: $e')),
      );
    }
  }
}
