import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Services/claude_service.dart';
import 'package:horizon/Services/openai_service.dart';

const _storage = FlutterSecureStorage();

class CloudProviderSettings extends StatelessWidget {
  const CloudProviderSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cloud Providers',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'API keys are stored in your device\'s secure storage.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        const _AnthropicKeyField(),
        const SizedBox(height: 16),
        const _OpenAIKeyField(),
      ],
    );
  }
}

class _AnthropicKeyField extends StatefulWidget {
  const _AnthropicKeyField();

  @override
  State<_AnthropicKeyField> createState() => _AnthropicKeyFieldState();
}

class _AnthropicKeyFieldState extends State<_AnthropicKeyField> {
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
      final v = await _storage.read(key: 'anthropic_api_key');
      if (!mounted) return;
      _controller.text = v ?? '';
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    final service = context.read<ClaudeService>();
    if (value.isEmpty) {
      try {
        await _storage.delete(key: 'anthropic_api_key');
      } catch (_) {}
      service.apiKey = '';
    } else {
      try {
        await _storage.write(key: 'anthropic_api_key', value: value);
      } catch (_) {}
      service.apiKey = value;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value.isEmpty ? 'Claude key cleared' : 'Claude key saved')),
      );
    }
  }

  @override
  void dispose() {
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
        labelText: 'Claude (Anthropic) API Key',
        hintText: 'sk-ant-...',
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
      onSubmitted: (_) => _save(),
    );
  }
}

class _OpenAIKeyField extends StatefulWidget {
  const _OpenAIKeyField();

  @override
  State<_OpenAIKeyField> createState() => _OpenAIKeyFieldState();
}

class _OpenAIKeyFieldState extends State<_OpenAIKeyField> {
  final _keyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  bool _obscure = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _keyController.text = await _storage.read(key: 'openai_api_key') ?? '';
      _baseUrlController.text = await _storage.read(key: 'openai_base_url') ?? '';
    } catch (_) {}
    if (mounted) setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final key = _keyController.text.trim();
    final base = _baseUrlController.text.trim();
    final service = context.read<OpenAIService>();

    try {
      if (key.isEmpty) {
        await _storage.delete(key: 'openai_api_key');
      } else {
        await _storage.write(key: 'openai_api_key', value: key);
      }
      if (base.isEmpty) {
        await _storage.delete(key: 'openai_base_url');
      } else {
        await _storage.write(key: 'openai_base_url', value: base);
      }
    } catch (_) {}

    service.apiKey = key;
    service.baseUrl = base.isEmpty ? null : base;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(key.isEmpty ? 'OpenAI key cleared' : 'OpenAI key saved')),
      );
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _keyController,
          enabled: _loaded,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'OpenAI API Key',
            hintText: 'sk-...',
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
          onSubmitted: (_) => _save(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _baseUrlController,
          enabled: _loaded,
          decoration: const InputDecoration(
            labelText: 'OpenAI Base URL (optional, for compatible endpoints)',
            hintText: 'https://api.openai.com',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _save(),
        ),
      ],
    );
  }
}
