import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/hermes_service.dart';

const _storage = FlutterSecureStorage();

/// Your own Hermes agent: its API server's address at home, the tunnel address
/// for everywhere else, and the API server key. Shows up in the model picker
/// as "Hermes agent"; a chat on it runs tools on that machine and asks here
/// before anything risky.
class HermesAgentSettings extends StatefulWidget {
  const HermesAgentSettings({super.key});

  @override
  State<HermesAgentSettings> createState() => HermesAgentSettingsState();
}

class HermesAgentSettingsState extends State<HermesAgentSettings> {
  final _url = TextEditingController();
  final _backup = TextEditingController();
  final _key = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;
  late bool _enabled;

  HermesService get _service => context.read<HermesService>();

  @override
  void initState() {
    super.initState();
    final box = Hive.box('settings');
    _enabled = box.get('enable_hermes', defaultValue: false) as bool;
    _url.text = box.get('hermes_base_url') as String? ?? '';
    _backup.text = box.get('hermes_backup_url') as String? ?? '';
    _load();
  }

  Future<void> _load() async {
    try {
      _key.text = await _storage.read(key: 'hermes_api_key') ?? '';
    } catch (_) {
      // Secure storage may be unavailable without a keyring; tolerate.
    } finally {
      if (mounted) setState(() => _loaded = true);
    }
  }

  void _setEnabled(bool value) {
    setState(() => _enabled = value);
    Hive.box('settings').put('enable_hermes', value);
    _service.enabled = value;
  }

  void _applyAddresses() {
    final box = Hive.box('settings');
    box.put('hermes_base_url', _url.text.trim());
    box.put('hermes_backup_url', _backup.text.trim());
    _service.endpoint
      ..primary = _url.text.trim()
      ..backup = _backup.text.trim()
      ..reset();
  }

  void _applyKey(String value) {
    final trimmed = value.trim();
    _service.apiKey = trimmed;
    // Same rule as every other provider here: pasting a key is the intent.
    if (trimmed.isNotEmpty && !_enabled) _setEnabled(true);
  }

  Future<void> _persistKey() async {
    final value = _key.text.trim();
    try {
      if (value.isEmpty) {
        await _storage.delete(key: 'hermes_api_key');
      } else {
        await _storage.write(key: 'hermes_api_key', value: value);
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    _applyAddresses();
    _applyKey(_key.text);
    await _persistKey();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Hermes agent saved')),
    );
  }

  @override
  void dispose() {
    // Only once loaded: before then the key field is empty, and persisting
    // would delete the stored key.
    if (_loaded) _persistKey();
    _url.dispose();
    _backup.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use the agent'),
          subtitle: Text(_enabled ? 'Shown in the model picker' : 'Off — agent hidden'),
          value: _enabled,
          onChanged: _setEnabled,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Address at home',
            hintText: 'http://172.16.23.30:8642',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _applyAddresses(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _backup,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Address from anywhere (optional)',
            hintText: 'https://agent.example.com',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _applyAddresses(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _key,
          enabled: _loaded,
          obscureText: _obscure,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'API server key',
            hintText: 'API_SERVER_KEY from the profile\'s .env',
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                IconButton(
                  icon: const Icon(Icons.save),
                  onPressed: _save,
                ),
              ],
            ),
          ),
          onChanged: _applyKey,
          onSubmitted: (_) => _save(),
        ),
      ],
    );
  }
}
