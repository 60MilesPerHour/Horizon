import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/home_assistant_service.dart';
import 'package:horizon/Pages/settings_page/subwidgets/home_assistant_settings.dart';

/// Home Assistant, on its own page: the connection, and what models may do
/// with it.
class HomeAssistantSettingsPage extends StatefulWidget {
  const HomeAssistantSettingsPage({super.key});

  @override
  State<HomeAssistantSettingsPage> createState() => _HomeAssistantSettingsPageState();
}

class _HomeAssistantSettingsPageState extends State<HomeAssistantSettingsPage> {
  Box get _settings => Hive.box('settings');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant')),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _section('Connection'),
          _sectionNote(
            'Your instance and a long-lived token. The token can do anything '
            'your account can — Home Assistant has no narrower scope for '
            'long-lived tokens — so issue one you are happy with.',
          ),
          const SizedBox(height: 16),
          const HomeAssistantSettings(),
          const Divider(height: 32),

          _section('What models can do'),
          _sectionNote(
            'Chats with tools switched on are offered these, and so is Horizon '
            'Voice — "turn off the kitchen lights" goes through them. A Hermes '
            'agent never sees them; it brings its own tools.',
          ),
          const SizedBox(height: 12),
          _toolsTile(),
          const SizedBox(height: 8),
          _toolList(),
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

  Widget _toolsTile() {
    final on = _settings.get('ha_tools_enabled', defaultValue: true) as bool;
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        secondary: Icon(on ? Icons.home_outlined : Icons.home_work_outlined),
        title: const Text('Let models use Home Assistant'),
        subtitle: Text(
          on
              ? 'Reading and controlling your house, when connected.'
              : 'Off — the connection is kept, but no chat is offered the tools.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        value: on,
        onChanged: (value) async {
          context.read<HomeAssistantService>().toolsEnabled = value;
          await _settings.put('ha_tools_enabled', value);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Widget _toolList() {
    final theme = Theme.of(context);
    const tools = [
      ('ha_list_entities', 'Find entities by name or domain'),
      ('ha_get_state', "Read one entity's state and attributes"),
      ('ha_call_service', 'Turn on, turn off, set, run — anything a service does'),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (name, what) in tools)
            ListTile(
              dense: true,
              title: Text(name),
              subtitle: Text(what, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
