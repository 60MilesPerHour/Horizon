import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/web_search_service.dart';

const _storage = FlutterSecureStorage();

/// Settings block for the web-search feature: pick a backend, enter the
/// SerpAPI key (secure storage) or SearXNG URL (settings box). Mirrors the
/// cloud-provider settings pattern — writes persist AND update the live
/// [WebSearchService] so changes take effect without a restart.
class WebSearchSettings extends StatefulWidget {
  const WebSearchSettings({super.key});

  @override
  State<WebSearchSettings> createState() => _WebSearchSettingsState();
}

class _WebSearchSettingsState extends State<WebSearchSettings> {
  final _serpKeyController = TextEditingController();
  final _searxngUrlController = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;
  WebSearchBackend _backend = WebSearchBackend.off;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final box = Hive.box('settings');
    _backend =
        WebSearchBackend.fromString(box.get('web_search_backend') as String?);
    _searxngUrlController.text = box.get('searxng_url') as String? ?? '';
    try {
      _serpKeyController.text = await _storage.read(key: 'serpapi_api_key') ?? '';
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final service = context.read<WebSearchService>();
    final box = Hive.box('settings');
    final serpKey = _serpKeyController.text.trim();
    final searxngUrl = _searxngUrlController.text.trim();

    await box.put('web_search_backend', _backend.name);
    await box.put('searxng_url', searxngUrl);
    try {
      if (serpKey.isEmpty) {
        await _storage.delete(key: 'serpapi_api_key');
      } else {
        await _storage.write(key: 'serpapi_api_key', value: serpKey);
      }
    } catch (_) {}

    // Push the new config into the live service.
    service.backend = _backend;
    service.serpApiKey = serpKey;
    service.searxngUrl = searxngUrl;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Web search settings saved')),
      );
    }
  }

  @override
  void dispose() {
    _serpKeyController.dispose();
    _searxngUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Web Search',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Enable per-chat web search from the chat\'s Configure menu. Pick a '
          'backend here. SerpAPI works anywhere with just a key; SearXNG points '
          'at your own instance and only works where it\'s reachable.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        SegmentedButton<WebSearchBackend>(
          segments: const [
            ButtonSegment(
              value: WebSearchBackend.off,
              label: Text('Off'),
              icon: Icon(Icons.block),
            ),
            ButtonSegment(
              value: WebSearchBackend.serpapi,
              label: Text('SerpAPI'),
              icon: Icon(Icons.cloud_outlined),
            ),
            ButtonSegment(
              value: WebSearchBackend.searxng,
              label: Text('SearXNG'),
              icon: Icon(Icons.dns_outlined),
            ),
          ],
          selected: {_backend},
          onSelectionChanged: _loaded
              ? (s) {
                  setState(() => _backend = s.first);
                  _save();
                }
              : null,
        ),
        if (_backend == WebSearchBackend.serpapi) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _serpKeyController,
            enabled: _loaded,
            obscureText: _obscure,
            decoration: InputDecoration(
              labelText: 'SerpAPI Key',
              hintText: 'serpapi.com private API key',
              border: const OutlineInputBorder(),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  IconButton(
                    icon: const Icon(Icons.save),
                    onPressed: _save,
                  ),
                ],
              ),
            ),
            onSubmitted: (_) => _save(),
          ),
        ],
        if (_backend == WebSearchBackend.searxng) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _searxngUrlController,
            enabled: _loaded,
            decoration: const InputDecoration(
              labelText: 'SearXNG Base URL',
              hintText: 'http://172.16.23.20:8888',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          Text(
            'The instance must expose the JSON API (format=json) and be '
            'reachable from this device.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
