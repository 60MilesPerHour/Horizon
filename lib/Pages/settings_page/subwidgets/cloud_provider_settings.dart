import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/claude_service.dart';
import 'package:horizon/Services/gemini_service.dart';
import 'package:horizon/Services/hermes_service.dart';
import 'package:horizon/Services/openai_service.dart';
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
          'API keys are stored in your device\'s secure storage. Ollama keeps '
          'working with or without any of this.',
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
          'actually do.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        const _OpenRouterKeyField(),
        const SizedBox(height: 24),
        const _HermesAgentSettings(),
        const SizedBox(height: 24),

        // For anyone who'd rather not have a middleman, or already pays one
        // of these directly. Folded away because for most setups OpenRouter
        // above covers all three.
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8.0),
          title: const Text('Direct provider keys'),
          subtitle: Text(
            'Optional — your own Anthropic, OpenAI or Google key',
            style: theme.textTheme.bodySmall,
          ),
          children: [
            Text(
              'Each talks to its company\'s API with no one in between. Off '
              'until you add a key; a provider switched off shows no models.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            _DirectProvider(
              label: 'Claude (Anthropic)',
              enableKey: 'enable_direct_anthropic',
              storageKey: 'anthropic_api_key',
              hint: 'sk-ant-...',
              isEnabled: () => context.read<ClaudeService>().enabled,
              setEnabled: (v) => context.read<ClaudeService>().enabled = v,
              setKey: (v) => context.read<ClaudeService>().apiKey = v,
            ),
            const SizedBox(height: 16),
            _DirectProvider(
              label: 'OpenAI',
              enableKey: 'enable_direct_openai',
              storageKey: 'openai_api_key',
              hint: 'sk-...',
              isEnabled: () => context.read<OpenAIService>().enabled,
              setEnabled: (v) => context.read<OpenAIService>().enabled = v,
              setKey: (v) => context.read<OpenAIService>().apiKey = v,
              // Any OpenAI-compatible endpoint, which is the one thing
              // OpenRouter can't stand in for.
              baseUrlStorageKey: 'openai_base_url',
              setBaseUrl: (v) => context.read<OpenAIService>().baseUrl =
                  v.isEmpty ? null : v,
            ),
            const SizedBox(height: 16),
            _DirectProvider(
              label: 'Gemini (Google)',
              enableKey: 'enable_direct_google',
              storageKey: 'google_api_key',
              hint: 'AIza...',
              isEnabled: () => context.read<GeminiService>().enabled,
              setEnabled: (v) => context.read<GeminiService>().enabled = v,
              setKey: (v) => context.read<GeminiService>().apiKey = v,
            ),
          ],
        ),
      ],
    );
  }
}

/// One direct provider: its switch, its key, and for OpenAI a base URL.
///
/// Behaves like the OpenRouter field rather than the v3 versions of these: the
/// key applies as you type and is saved on the way out, and pasting one
/// switches the provider on. The v3 fields only saved from their save button,
/// and a pasted key with the switch left off just looks like missing models.
class _DirectProvider extends StatefulWidget {
  final String label;
  final String enableKey;
  final String storageKey;
  final String hint;
  final bool Function() isEnabled;
  final void Function(bool) setEnabled;
  final void Function(String) setKey;
  final String? baseUrlStorageKey;
  final void Function(String)? setBaseUrl;

  const _DirectProvider({
    required this.label,
    required this.enableKey,
    required this.storageKey,
    required this.hint,
    required this.isEnabled,
    required this.setEnabled,
    required this.setKey,
    this.baseUrlStorageKey,
    this.setBaseUrl,
  });

  @override
  State<_DirectProvider> createState() => _DirectProviderState();
}

class _DirectProviderState extends State<_DirectProvider> {
  final _key = TextEditingController();
  final _baseUrl = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _enabled = widget.isEnabled();
    _load();
  }

  Future<void> _load() async {
    try {
      _key.text = await _storage.read(key: widget.storageKey) ?? '';
      final baseKey = widget.baseUrlStorageKey;
      if (baseKey != null) {
        _baseUrl.text = await _storage.read(key: baseKey) ?? '';
      }
    } catch (_) {
      // Secure storage may be unavailable without a keyring; tolerate.
    } finally {
      if (mounted) setState(() => _loaded = true);
    }
  }

  void _setEnabled(bool value) {
    setState(() => _enabled = value);
    Hive.box('settings').put(widget.enableKey, value);
    widget.setEnabled(value);
  }

  void _applyKey(String value) {
    final trimmed = value.trim();
    widget.setKey(trimmed);
    if (trimmed.isNotEmpty && !_enabled) _setEnabled(true);
  }

  Future<void> _persist() async {
    Future<void> put(String key, String value) async {
      try {
        if (value.isEmpty) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: value);
        }
      } catch (_) {}
    }

    await put(widget.storageKey, _key.text.trim());
    final baseKey = widget.baseUrlStorageKey;
    if (baseKey != null) await put(baseKey, _baseUrl.text.trim());
  }

  Future<void> _save() async {
    _applyKey(_key.text);
    widget.setBaseUrl?.call(_baseUrl.text.trim());
    await _persist();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_key.text.trim().isEmpty
            ? '${widget.label} key cleared'
            : '${widget.label} key saved'),
      ),
    );
  }

  @override
  void dispose() {
    // Saved on the way out, so closing Settings after a paste keeps the key.
    // Only once loaded: before then the fields are empty, and persisting
    // would delete the stored key.
    if (_loaded) _persist();
    _key.dispose();
    _baseUrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(widget.label),
          subtitle: Text(_enabled ? 'Enabled' : 'Disabled — models hidden'),
          value: _enabled,
          onChanged: _setEnabled,
        ),
        TextField(
          controller: _key,
          enabled: _loaded,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: '${widget.label} API Key',
            hintText: widget.hint,
            border: const OutlineInputBorder(),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon:
                      Icon(_obscure ? Icons.visibility : Icons.visibility_off),
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
        if (widget.baseUrlStorageKey != null) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _baseUrl,
            enabled: _loaded,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Base URL (optional, for compatible endpoints)',
              hintText: 'https://api.openai.com',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => widget.setBaseUrl?.call(v.trim()),
            onSubmitted: (_) => _save(),
          ),
        ],
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

/// Your own Hermes agent: its API server's address at home, the tunnel address
/// for everywhere else, and the API server key. Shows up in the model picker
/// as "Hermes agent"; a chat on it runs tools on that machine and asks here
/// before anything risky.
class _HermesAgentSettings extends StatefulWidget {
  const _HermesAgentSettings();

  @override
  State<_HermesAgentSettings> createState() => _HermesAgentSettingsState();
}

class _HermesAgentSettingsState extends State<_HermesAgentSettings> {
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
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Hermes agent'),
          subtitle: Text(_enabled ? 'Enabled' : 'Disabled — agent hidden'),
          value: _enabled,
          onChanged: _setEnabled,
        ),
        Text(
          'A Hermes agent on one of your machines, through its API server. It '
          'runs its own tools there — terminal, files, web, memory — and asks '
          'here before running anything risky. Uses the Cloudflare Access '
          'token from Server settings for the remote address.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
