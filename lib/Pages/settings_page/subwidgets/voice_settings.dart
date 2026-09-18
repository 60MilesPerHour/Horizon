import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/voice/speech_recognition_service.dart';
import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Widgets/model_selection_bottom_sheet.dart';

const _storage = FlutterSecureStorage();

/// Voice-mode configuration: which model answers, which voice speaks, and
/// whether Horizon holds the system assistant role.
class VoiceSettings extends StatefulWidget {
  const VoiceSettings({super.key});

  @override
  State<VoiceSettings> createState() => _VoiceSettingsState();
}

class _VoiceSettingsState extends State<VoiceSettings> {
  static const MethodChannel _assistantChannel =
      MethodChannel('com.miles.horizon/assistant');

  final _keyController = TextEditingController();
  bool _obscureKey = true;
  bool _loadedKey = false;

  /// Null until the platform answers, or on a platform that has no such role.
  bool? _isDefaultAssistant;

  List<SpeechVoice> _elevenLabsVoices = const [];
  bool _loadingVoices = false;

  @override
  void initState() {
    super.initState();
    _loadKey();
    _refreshAssistantRole();
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _loadKey() async {
    try {
      final key = await _storage.read(key: 'elevenlabs_api_key');
      if (!mounted) return;
      _keyController.text = key ?? '';
    } catch (_) {
      // No keyring; the in-memory key still works for this session.
    } finally {
      if (mounted) setState(() => _loadedKey = true);
    }
  }

  Future<void> _refreshAssistantRole() async {
    try {
      final result =
          await _assistantChannel.invokeMethod<bool>('isDefaultAssistant');
      if (!mounted) return;
      setState(() => _isDefaultAssistant = result);
    } on MissingPluginException {
      // Desktop / iOS: no digital-assistant role to hold.
      if (mounted) setState(() => _isDefaultAssistant = null);
    } catch (_) {
      if (mounted) setState(() => _isDefaultAssistant = null);
    }
  }

  SpeechSynthesisService get _synthesis => context.read<SpeechSynthesisService>();

  Box get _settings => Hive.box('settings');

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
        Text(
          'Voice mode talks to one long-lived chat — the assistant chat — so it '
          'remembers the last thing you asked. It appears in the chat list '
          'like any other conversation.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        _assistantRoleTile(theme),
        const SizedBox(height: 8),
        _assistantModelTile(theme),
        const Divider(height: 32),
        _engineSelector(theme),
        if (_synthesis.engine == SpeechEngine.elevenLabs) ...[
          const SizedBox(height: 8),
          _elevenLabsKeyField(),
          const SizedBox(height: 8),
          _elevenLabsVoicePicker(theme),
        ],
        const SizedBox(height: 8),
        _rateSlider(theme),
        const SizedBox(height: 8),
        _recognitionLocalePicker(theme),
      ],
    );
  }

  Widget _assistantRoleTile(ThemeData theme) {
    if (_isDefaultAssistant == null) {
      // Nothing to say on a platform without the role.
      return const SizedBox.shrink();
    }

    final isDefault = _isDefaultAssistant!;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(
          isDefault ? Icons.check_circle_outline : Icons.assistant_outlined,
          color: isDefault ? theme.colorScheme.primary : null,
        ),
        title: Text(isDefault
            ? 'Horizon is your digital assistant'
            : 'Set Horizon as your digital assistant'),
        subtitle: Text(
          isDefault
              ? 'Long-press power or use the assist gesture to open voice mode.'
              : 'Android only lets you choose this yourself — Horizon can open '
                  'the right settings screen, but not set it.',
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          bool opened = false;
          try {
            opened = await _assistantChannel
                    .invokeMethod<bool>('openAssistantSettings') ??
                false;
          } catch (_) {
            opened = false;
          }
          if (!opened) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                  'Could not open that screen. Look for Settings → Apps → '
                  'Default apps → Digital assistant app.',
                ),
              ),
            );
          }
          // The user may flip it while away; re-read on return.
          await _refreshAssistantRole();
        },
      ),
    );
  }

  Widget _assistantModelTile(ThemeData theme) {
    final chatProvider = context.watch<ChatProvider>();
    final selected = _settings.get('assistant_model') as String? ??
        chatProvider.assistantChatModel;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.psychology_outlined),
        title: const Text('Assistant model'),
        subtitle: Text(
          selected ?? 'Whatever is available',
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final model = await showModelSelectionBottomSheet(
            context: context,
            title: 'Assistant Model',
            currentModelName: selected,
          );
          if (model == null) return;
          await _settings.put('assistant_model', model.name);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  Widget _engineSelector(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Voice', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        SegmentedButton<SpeechEngine>(
          segments: const [
            ButtonSegment(
              value: SpeechEngine.system,
              icon: Icon(Icons.phone_android),
              label: Text('Device'),
            ),
            ButtonSegment(
              value: SpeechEngine.elevenLabs,
              icon: Icon(Icons.graphic_eq),
              label: Text('ElevenLabs'),
            ),
          ],
          selected: {_synthesis.engine},
          onSelectionChanged: (selection) async {
            final engine = selection.first;
            setState(() => _synthesis.engine = engine);
            await _settings.put('voice_engine', engine.storageValue);
            if (engine == SpeechEngine.elevenLabs) await _loadElevenLabsVoices();
          },
        ),
        const SizedBox(height: 4),
        Text(
          _synthesis.engine == SpeechEngine.elevenLabs
              ? 'Needs a key and a network round-trip per sentence. Falls back '
                  'to the device voice if a request fails, so a reply is never '
                  'left half-spoken.'
              : 'Free, offline, and instant. Sounds like a satnav.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _elevenLabsKeyField() {
    return TextField(
      controller: _keyController,
      enabled: _loadedKey,
      obscureText: _obscureKey,
      decoration: InputDecoration(
        labelText: 'ElevenLabs API Key',
        hintText: 'sk_...',
        border: const OutlineInputBorder(),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscureKey = !_obscureKey),
            ),
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveKey,
            ),
          ],
        ),
      ),
      // Applied as typed so the key is live without an explicit save.
      onChanged: (value) => _synthesis.elevenLabsKey = value.trim(),
      onSubmitted: (_) => _saveKey(),
    );
  }

  Future<void> _saveKey() async {
    final value = _keyController.text.trim();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (value.isEmpty) {
        await _storage.delete(key: 'elevenlabs_api_key');
      } else {
        await _storage.write(key: 'elevenlabs_api_key', value: value);
      }
    } catch (_) {}
    _synthesis.elevenLabsKey = value;

    if (value.isNotEmpty) await _loadElevenLabsVoices();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          value.isEmpty ? 'ElevenLabs key cleared' : 'ElevenLabs key saved',
        ),
      ),
    );
  }

  Future<void> _loadElevenLabsVoices() async {
    if (_synthesis.elevenLabsKey.isEmpty) return;
    setState(() => _loadingVoices = true);
    final voices = await _synthesis.listElevenLabsVoices();
    if (!mounted) return;
    setState(() {
      _elevenLabsVoices = voices;
      _loadingVoices = false;
    });
  }

  Widget _elevenLabsVoicePicker(ThemeData theme) {
    if (_loadingVoices) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8.0),
        child: LinearProgressIndicator(),
      );
    }

    if (_elevenLabsVoices.isEmpty) {
      return Row(
        children: [
          Expanded(
            child: Text(
              _synthesis.elevenLabsKey.isEmpty
                  ? 'Add a key to list your voices.'
                  : 'No voices loaded — the default (Rachel) will be used.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (_synthesis.elevenLabsKey.isNotEmpty)
            TextButton(
              onPressed: _loadElevenLabsVoices,
              child: const Text('Load voices'),
            ),
        ],
      );
    }

    final currentId = _synthesis.elevenLabsVoiceId;
    final hasCurrent = _elevenLabsVoices.any((v) => v.id == currentId);

    return DropdownButtonFormField<String>(
      // `value`, not `initialValue`: CI pins Flutter 3.27, where the
      // parameter had not been renamed yet. Local analysis flags it as
      // deprecated, which is the right trade against a broken build.
      // ignore: deprecated_member_use
      value: hasCurrent ? currentId : _elevenLabsVoices.first.id,
      decoration: const InputDecoration(
        labelText: 'ElevenLabs voice',
        border: OutlineInputBorder(),
      ),
      items: _elevenLabsVoices
          .map((v) => DropdownMenuItem(value: v.id, child: Text(v.name)))
          .toList(),
      onChanged: (value) async {
        if (value == null) return;
        setState(() => _synthesis.elevenLabsVoiceId = value);
        await _settings.put('elevenlabs_voice_id', value);
      },
    );
  }

  Widget _rateSlider(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Speaking rate — ${_synthesis.rate.toStringAsFixed(2)}×',
          style: theme.textTheme.titleSmall,
        ),
        Slider(
          value: _synthesis.rate.clamp(0.7, 1.5),
          min: 0.7,
          max: 1.5,
          divisions: 16,
          label: '${_synthesis.rate.toStringAsFixed(2)}×',
          onChanged: (value) => setState(() => _synthesis.rate = value),
          onChangeEnd: (value) async {
            _synthesis.invalidateVoiceSettings();
            await _settings.put('voice_rate', value);
          },
        ),
      ],
    );
  }

  Widget _recognitionLocalePicker(ThemeData theme) {
    final current = _settings.get('voice_locale') as String? ?? '';

    return FutureBuilder<List<({String id, String name})>>(
      future: context.read<SpeechRecognitionService>().locales(),
      builder: (context, snapshot) {
        final locales = snapshot.data ?? const [];
        if (locales.isEmpty) {
          return Text(
            snapshot.connectionState == ConnectionState.waiting
                ? 'Checking available speech languages…'
                : 'No speech recogniser is available on this device, so voice '
                    'input will not work. Replies can still be read aloud.',
            style: theme.textTheme.bodySmall,
          );
        }

        final value = locales.any((l) => l.id == current) ? current : '';
        return DropdownButtonFormField<String>(
          // See the note on the voice picker above.
          // ignore: deprecated_member_use
          value: value,
          decoration: const InputDecoration(
            labelText: 'Speech recognition language',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('Device default')),
            ...locales.map(
              (l) => DropdownMenuItem(value: l.id, child: Text(l.name)),
            ),
          ],
          onChanged: (selected) async {
            await _settings.put('voice_locale', selected ?? '');
            if (mounted) setState(() {});
          },
        );
      },
    );
  }
}
