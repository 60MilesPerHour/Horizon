import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/openrouter_service.dart';

const _storage = FlutterSecureStorage();

class CloudProviderSettings extends StatelessWidget {
  const CloudProviderSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cloud Models',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Your key is stored in the device\'s secure storage. Ollama keeps '
          'working with or without it.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        _ProviderKillSwitch(
          label: 'OpenRouter',
          hiveKey: 'enable_openrouter',
          onChanged: (v) => context.read<OpenRouterService>().enabled = v,
        ),
        Text(
          'One key for Claude, GPT, Gemini, Llama, Qwen and several hundred '
          'others, on one bill. Tool support and image input are read from '
          'OpenRouter per model, so the picker shows what each one can '
          'actually do. Horizon spoke to Anthropic, OpenAI and Google '
          'directly until v4.0.0; those chats now run here.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        const _OpenRouterKeyField(),
      ],
    );
  }
}

class _OpenRouterKeyField extends StatefulWidget {
  const _OpenRouterKeyField();

  @override
  State<_OpenRouterKeyField> createState() => _OpenRouterKeyFieldState();
}

class _OpenRouterKeyFieldState extends State<_OpenRouterKeyField> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final v = await _storage.read(key: 'openrouter_api_key');
      if (!mounted) return;
      _controller.text = v ?? '';
    } catch (_) {
      // Secure storage may be unavailable without a keyring; tolerate.
    } finally {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    final service = context.read<OpenRouterService>();
    try {
      if (value.isEmpty) {
        await _storage.delete(key: 'openrouter_api_key');
      } else {
        await _storage.write(key: 'openrouter_api_key', value: value);
      }
    } catch (_) {}
    service.apiKey = value;

    // Pasting a key is the whole intent — leaving the provider switched off
    // afterwards just makes the models silently missing.
    if (value.isNotEmpty && !service.enabled) {
      service.enabled = true;
      await Hive.box('settings').put('enable_openrouter', true);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            value.isEmpty ? 'OpenRouter key cleared' : 'OpenRouter key saved',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    // Save on the way out so a pasted key isn't lost by closing Settings
    // without pressing anything — the exact bug that made web search look
    // broken in v3.6.2.
    final value = _controller.text.trim();
    if (value.isNotEmpty) {
      _storage.write(key: 'openrouter_api_key', value: value).catchError((_) {});
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      enabled: _loaded,
      obscureText: _obscure,
      decoration: InputDecoration(
        labelText: 'OpenRouter API Key',
        hintText: 'sk-or-v1-...',
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
      // Apply as you type so the key is live the moment the user leaves the
      // field, with no explicit save step; dispose() then persists it. Pasting
      // and closing Settings without pressing save is how the SerpAPI key got
      // silently dropped in v3.6.2.
      onChanged: (value) {
        final trimmed = value.trim();
        final service = context.read<OpenRouterService>();
        service.apiKey = trimmed;
        if (trimmed.isNotEmpty && !service.enabled) {
          service.enabled = true;
          Hive.box('settings').put('enable_openrouter', true);
        }
      },
      onSubmitted: (_) => _save(),
    );
  }
}

/// Per-provider hard kill switch. Off means the provider is fully dead — its
/// models never appear and it can never be selected — regardless of key state.
/// Persists to the Hive `settings` box and mutates the live service.
class _ProviderKillSwitch extends StatefulWidget {
  final String label;
  final String hiveKey;
  final void Function(bool) onChanged;

  const _ProviderKillSwitch({
    required this.label,
    required this.hiveKey,
    required this.onChanged,
  });

  @override
  State<_ProviderKillSwitch> createState() => _ProviderKillSwitchState();
}

class _ProviderKillSwitchState extends State<_ProviderKillSwitch> {
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _enabled =
        Hive.box('settings').get(widget.hiveKey, defaultValue: false) as bool;
  }

  void _toggle(bool value) {
    setState(() => _enabled = value);
    Hive.box('settings').put(widget.hiveKey, value);
    widget.onChanged(value);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${widget.label} ${value ? 'enabled' : 'disabled'}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(widget.label),
      subtitle: Text(_enabled ? 'Enabled' : 'Disabled — models hidden'),
      value: _enabled,
      onChanged: _toggle,
    );
  }
}
