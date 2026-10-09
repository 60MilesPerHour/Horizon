import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/hermes_commands.dart';
import 'package:horizon/Services/hermes_service.dart';
import 'package:horizon/Pages/settings_page/subwidgets/hermes_agent_settings.dart';

/// Everything Hermes, on its own page.
///
/// The agent isn't a cloud model — it runs tools on your own machine, keeps
/// its own sessions, and has commands — so it outgrew a block under the
/// OpenRouter key.
class HermesSettingsPage extends StatefulWidget {
  const HermesSettingsPage({super.key});

  @override
  State<HermesSettingsPage> createState() => _HermesSettingsPageState();
}

class _HermesSettingsPageState extends State<HermesSettingsPage> {
  Box get _settings => Hive.box('settings');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hermes Agent')),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _section('Connection'),
          _sectionNote(
            'A Hermes agent on one of your machines, through its API server. It '
            'runs its own tools there — terminal, files, web, memory — and asks '
            'here before running anything risky. The remote address uses the '
            'Cloudflare Access token from Ollama Server settings.',
          ),
          const SizedBox(height: 8),
          const HermesAgentSettings(),
          const Divider(height: 32),

          _section('Thinking'),
          _sectionNote(
            'Most of a slow reply is the model reasoning before it answers, and '
            "the agent's API doesn't stream that, so it reads as a long wait. "
            'Off answers in a few seconds but plans less on multi-step jobs. '
            'This is the level every chat starts on; /think changes one chat.',
          ),
          const SizedBox(height: 12),
          _thinkingSelector(),
          const Divider(height: 32),

          _section('Commands'),
          _sectionNote(
            'Type / in a chat with the agent. These are answered by Horizon, '
            "not sent: the agent's API has no commands of its own. A message "
            'that only starts with a slash, like a path, still goes through.',
          ),
          const SizedBox(height: 8),
          _commandList(),
          const Divider(height: 32),

          _section('Sessions'),
          _sectionNote(
            'Each chat is one session on the agent, which keeps the history '
            'there. Forgetting them starts every chat on a fresh session, '
            'seeded with what is on screen.',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('Forget all agent sessions'),
              onPressed: _forgetSessions,
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 4.0),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
      );

  Widget _sectionNote(String text) => Text(
        text,
        style: Theme.of(context).textTheme.bodySmall,
      );

  Widget _thinkingSelector() {
    final level = _settings.get(HermesService.thinkingKey, defaultValue: '') as String;
    return SegmentedButton<String>(
      segments: const [
        ButtonSegment(value: '', label: Text('Default')),
        ButtonSegment(value: 'none', label: Text('Off')),
        ButtonSegment(value: 'low', label: Text('Low')),
        ButtonSegment(value: 'medium', label: Text('Medium')),
        ButtonSegment(value: 'high', label: Text('High')),
      ],
      selected: {
        // 'minimal' is reachable through /think only; show it as Low.
        level == 'minimal' ? 'low' : level,
      },
      showSelectedIcon: false,
      onSelectionChanged: (selection) async {
        await _settings.put(HermesService.thinkingKey, selection.first);
        if (mounted) setState(() {});
      },
    );
  }

  Widget _commandList() {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final c in HermesCommand.all)
            ListTile(
              dense: true,
              title: Text('/${c.name}${c.args == null ? '' : ' ${c.args}'}'),
              subtitle: Text(c.description, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Future<void> _forgetSessions() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Forget all agent sessions?'),
        content: const Text(
          "Your chats stay as they are. The agent's next turn in each one "
          'starts a new session with the transcript passed along.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Forget')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<HermesService>().forgetAllSessions();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Agent sessions forgotten')),
    );
  }
}
