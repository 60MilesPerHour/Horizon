import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/home_assistant_service.dart';

const _storage = FlutterSecureStorage();

/// Home Assistant connection settings.
///
/// The instance URL is ordinary config (Hive), the long-lived token is a
/// secret (keystore). Both are applied to the live service as they're typed,
/// so the tools work without a restart — and "Test connection" exists because
/// a wrong URL or an expired token should fail here, visibly, rather than
/// mid-sentence in a voice conversation.
class HomeAssistantSettings extends StatefulWidget {
  const HomeAssistantSettings({super.key});

  @override
  State<HomeAssistantSettings> createState() => _HomeAssistantSettingsState();
}

class _HomeAssistantSettingsState extends State<HomeAssistantSettings> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;
  bool _testing = false;
  String? _testResult;
  bool _testFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _urlController.text =
        (Hive.box('settings').get('ha_base_url') as String?) ?? '';
    try {
      _tokenController.text = await _storage.read(key: 'ha_token') ?? '';
    } catch (_) {
      // Keystore may be unavailable (Linux without a keyring); tolerate.
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    // Persist on the way out, so a pasted token isn't lost by closing
    // Settings without pressing anything — the bug that made web search look
    // broken in v3.6.2.
    _persist();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _persist() async {
    final url = _urlController.text.trim();
    final token = _tokenController.text.trim();
    await Hive.box('settings').put('ha_base_url', url);
    try {
      if (token.isEmpty) {
        await _storage.delete(key: 'ha_token');
      } else {
        await _storage.write(key: 'ha_token', value: token);
      }
    } catch (_) {}
  }

  void _applyLive() {
    final service = context.read<HomeAssistantService>();
    service.baseUrl = _urlController.text.trim();
    service.token = _tokenController.text.trim();
  }

  Future<void> _test() async {
    // Read the service before the first await: `context` must not be touched
    // across an async gap.
    final service = context.read<HomeAssistantService>();
    _applyLive();
    await _persist();

    if (!service.isConfigured) {
      setState(() {
        _testFailed = true;
        _testResult = 'Enter both the instance URL and a long-lived token.';
      });
      return;
    }

    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      final description = await service.ping();
      if (!mounted) return;
      setState(() {
        _testFailed = false;
        _testResult = 'Connected to $description';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testFailed = true;
        _testResult = e.toString();
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Home Assistant',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Lets the model read your entities and call services: check a '
          'sensor, turn something on, set a temperature, run a scene. It can '
          'do anything this token can do, so issue it a token you are happy '
          'with — Home Assistant has no finer-grained scope for long-lived '
          'tokens.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _urlController,
          enabled: _loaded,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Instance URL',
            hintText: 'http://homeassistant.local:8123',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => _applyLive(),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _tokenController,
          enabled: _loaded,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'Long-lived access token',
            hintText: 'eyJhbGciOi...',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
          onChanged: (_) => _applyLive(),
        ),
        const SizedBox(height: 8),
        Text(
          'Create one in Home Assistant under your profile → Security → '
          'Long-lived access tokens.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering),
              label: Text(_testing ? 'Testing…' : 'Test connection'),
            ),
          ],
        ),
        if (_testResult != null) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _testFailed ? Icons.error_outline : Icons.check_circle_outline,
                size: 18,
                color: _testFailed
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _testResult!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _testFailed ? theme.colorScheme.error : null,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
