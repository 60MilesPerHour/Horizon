import 'package:flutter/material.dart';

/// Entry point to the Voice settings page.
///
/// Voice carries three independent credentials (ElevenLabs for speech out,
/// and optionally ElevenLabs or a Whisper server for speech in) plus the
/// assistant model and role. Inline, that turned the main Settings page into
/// a wall of key fields, so it lives on its own page.
class VoiceSettingsTile extends StatelessWidget {
  const VoiceSettingsTile({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Voice',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: const Text('Voice mode'),
            subtitle: Text(
              'Assistant model, speech recognition, and the voice that reads '
              'replies.',
              style: theme.textTheme.bodySmall,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.pushNamed(context, '/settings/voice'),
          ),
        ),
      ],
    );
  }
}
