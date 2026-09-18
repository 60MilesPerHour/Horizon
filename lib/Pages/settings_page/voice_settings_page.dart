import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';

import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Services/voice/stt/elevenlabs_transcriber.dart';
import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Services/voice/stt/speech_input_service.dart';
import 'package:horizon/Services/voice/stt/whisper_transcriber.dart';
import 'package:horizon/Pages/settings_page/subwidgets/speech_server_fields.dart';
import 'package:horizon/Widgets/model_selection_bottom_sheet.dart';

const _storage = FlutterSecureStorage();

/// Everything voice, on its own page.
///
/// Voice grew three independent credentials — ElevenLabs for speech out,
/// optionally ElevenLabs or a Whisper server for speech in — and burying them
/// among the chat providers made the main Settings page a wall of key fields.
class VoiceSettingsPage extends StatefulWidget {
  const VoiceSettingsPage({super.key});

  @override
  State<VoiceSettingsPage> createState() => _VoiceSettingsPageState();
}

class _VoiceSettingsPageState extends State<VoiceSettingsPage> {
  static const MethodChannel _assistantChannel =
      MethodChannel('com.miles.horizon/assistant');

  bool? _isDefaultAssistant;

  List<SpeechVoice> _elevenLabsVoices = const [];
  bool _loadingVoices = false;
  bool _previewingVoice = false;

  @override
  void initState() {
    super.initState();
    _refreshAssistantRole();
  }

  Box get _settings => Hive.box('settings');
  SpeechSynthesisService get _synthesis =>
      context.read<SpeechSynthesisService>();
  SpeechInputService get _input => context.read<SpeechInputService>();
  WhisperTranscriber get _whisper => context.read<WhisperTranscriber>();
  ElevenLabsTranscriber get _scribe => context.read<ElevenLabsTranscriber>();

  Future<void> _refreshAssistantRole() async {
    try {
      final result =
          await _assistantChannel.invokeMethod<bool>('isDefaultAssistant');
      if (mounted) setState(() => _isDefaultAssistant = result);
    } catch (_) {
      // Desktop / iOS have no such role.
      if (mounted) setState(() => _isDefaultAssistant = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Voice')),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _section('Assistant'),
          _assistantRoleTile(),
          const SizedBox(height: 8),
          _assistantModelTile(),
          const SizedBox(height: 8),
          _speakRepliesTile(),
          const Divider(height: 32),

          _section('Speech to text'),
          _sectionNote(
            'The device recogniser is free, works offline once a language pack '
            'is installed, and shows words as you speak. The other two '
            'transcribe a finished recording, so they are more accurate but '
            'show a level meter instead of live text. If the one you pick '
            "isn't reachable, the device recogniser covers that turn rather "
            'than losing what you said.',
          ),
          const SizedBox(height: 12),
          _sttBackendSelector(),
          const SizedBox(height: 12),
          if (_input.backend == SttBackend.whisper) _whisperFields(),
          if (_input.backend == SttBackend.elevenLabs) _scribeNote(),
          const SizedBox(height: 8),
          _recognitionLocalePicker(),
          const Divider(height: 32),

          _section('Text to speech'),
          _engineSelector(),
          if (_synthesis.engine == SpeechEngine.selfHosted) ...[
            const SizedBox(height: 12),
            _selfHostedTtsFields(),
          ],
          if (_synthesis.engine == SpeechEngine.elevenLabs) ...[
            const SizedBox(height: 12),
            _elevenLabsKeyField(),
            const SizedBox(height: 12),
            _elevenLabsVoicePicker(),
          ],
          const SizedBox(height: 8),
          _rateSlider(),
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

  // ============================================================
  // Assistant
  // ============================================================

  Widget _assistantRoleTile() {
    if (_isDefaultAssistant == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
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
                  'the right screen, but not set it.',
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () async {
          final messenger = ScaffoldMessenger.of(context);
          var opened = false;
          try {
            opened = await _assistantChannel
                    .invokeMethod<bool>('openAssistantSettings') ??
                false;
          } catch (_) {
            opened = false;
          }
          if (!opened) {
            messenger.showSnackBar(const SnackBar(
              content: Text(
                'Could not open that screen. Look for Settings → Apps → '
                'Default apps → Digital assistant app.',
              ),
            ));
          }
          await _refreshAssistantRole();
        },
      ),
    );
  }

  Widget _assistantModelTile() {
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
          style: Theme.of(context).textTheme.bodySmall,
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

  Widget _speakRepliesTile() {
    final on = _settings.get('voice_speak_replies', defaultValue: true) as bool;
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        secondary: Icon(
          on ? Icons.volume_up_outlined : Icons.volume_off_outlined,
        ),
        title: const Text('Speak replies'),
        subtitle: Text(
          on
              ? 'Answers are read aloud as they arrive.'
              : 'Replies stay on screen — voice mode becomes dictation.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        value: on,
        onChanged: (value) async {
          await _settings.put('voice_speak_replies', value);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  // ============================================================
  // Speech to text
  // ============================================================

  Widget _sttBackendSelector() {
    return SegmentedButton<SttBackend>(
      segments: const [
        ButtonSegment(
          value: SttBackend.device,
          icon: Icon(Icons.phone_android),
          label: Text('Device'),
        ),
        ButtonSegment(
          value: SttBackend.whisper,
          icon: Icon(Icons.dns_outlined),
          label: Text('Whisper'),
        ),
        ButtonSegment(
          value: SttBackend.elevenLabs,
          icon: Icon(Icons.cloud_outlined),
          label: Text('Scribe'),
        ),
      ],
      selected: {_input.backend},
      onSelectionChanged: (selection) async {
        final backend = selection.first;
        setState(() => _input.backend = backend);
        await _settings.put('stt_backend', backend.storageValue);
      },
    );
  }

  Widget _whisperFields() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Any server speaking the OpenAI transcription API: Speaches, '
          'faster-whisper-server, whisper.cpp, LocalAI. Tap the scan icon to '
          'find one on this network rather than typing an address.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        SpeechServerFields(
          task: 'automatic-speech-recognition',
          initialBaseUrl: _settings.get('whisper_base_url') as String? ?? '',
          initialModel: _settings.get('whisper_model') as String? ?? '',
          onBaseUrlChanged: (value) {
            _whisper.baseUrl = value;
            _settings.put('whisper_base_url', value);
          },
          onModelChanged: (value) {
            _whisper.model = value;
            _settings.put('whisper_model', value);
          },
        ),
        const SizedBox(height: 8),
        _PersistedField(
          label: 'API key (optional)',
          hint: 'Only for OpenAI / Groq',
          obscure: true,
          secureStorageKey: 'whisper_api_key',
          onChanged: (value) => _whisper.apiKey = value,
        ),
      ],
    );
  }

  Widget _scribeNote() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _scribe.isConfigured
              ? 'Uses the same ElevenLabs key as speech output. Billed by '
                  'audio duration — a few seconds per turn.'
              : 'Needs an ElevenLabs key. Add one under Text to speech below; '
                  'the same key covers both.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: _scribe.isConfigured ? null : theme.colorScheme.error,
          ),
        ),
      ],
    );
  }

  Widget _recognitionLocalePicker() {
    final current = _settings.get('voice_locale') as String? ?? '';

    return FutureBuilder<List<({String id, String name})>>(
      future: _input.locales(),
      builder: (context, snapshot) {
        final locales = snapshot.data ?? const [];
        if (locales.isEmpty) {
          return Text(
            snapshot.connectionState == ConnectionState.waiting
                ? 'Checking available speech languages…'
                : 'The device reports no speech languages. A Whisper server or '
                    'Scribe will still work.',
            style: Theme.of(context).textTheme.bodySmall,
          );
        }

        final value = locales.any((l) => l.id == current) ? current : '';
        return DropdownButtonFormField<String>(
          initialValue: value,
          decoration: const InputDecoration(
            labelText: 'Language',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(
              value: '',
              child: Text('Automatic / device default'),
            ),
            ...locales.map(
              (l) => DropdownMenuItem(value: l.id, child: Text(l.name)),
            ),
          ],
          onChanged: (selected) async {
            final id = selected ?? '';
            _input.localeId = id;
            await _settings.put('voice_locale', id);
            if (mounted) setState(() {});
          },
        );
      },
    );
  }

  // ============================================================
  // Text to speech
  // ============================================================

  Widget _engineSelector() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<SpeechEngine>(
          segments: const [
            ButtonSegment(
              value: SpeechEngine.system,
              icon: Icon(Icons.phone_android),
              label: Text('Device'),
            ),
            ButtonSegment(
              value: SpeechEngine.selfHosted,
              icon: Icon(Icons.dns_outlined),
              label: Text('Self-hosted'),
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
            if (engine == SpeechEngine.elevenLabs) {
              await _loadElevenLabsVoices();
            }
          },
        ),
        if (_synthesis.engine == SpeechEngine.system)
          Padding(
            padding: const EdgeInsets.only(top: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Hear the device voice as it will read replies.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                _previewButton(
                  SpeechEngine.system,
                  null,
                  locale: _settings.get('voice_tts_locale') as String?,
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Text(
          switch (_synthesis.engine) {
            SpeechEngine.elevenLabs =>
              'One network round-trip per sentence, with the next clip fetched '
                  'while the current one plays. A failed request falls back to '
                  'the device voice for that sentence rather than dropping it.',
            SpeechEngine.selfHosted =>
              'Your own server on the OpenAI /v1/audio/speech endpoint — '
                  'Speaches with Kokoro is the usual one, and the same '
                  'container also serves transcription above. No keys, no '
                  'per-hour cost.',
            SpeechEngine.system =>
              'Free, offline, and instant. Sounds like a satnav.',
          },
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _selfHostedTtsFields() {
    final theme = Theme.of(context);
    // Speaches serves transcription and speech from one container, so default
    // to the address already entered above rather than making it be typed
    // twice.
    final whisperUrl =
        (_settings.get('whisper_base_url') as String? ?? '').trim();
    final current = _synthesis.selfHostedBaseUrl.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (current.isEmpty && whisperUrl.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              'Prefilled from your transcription server — Speaches serves '
              'both from one address.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        SpeechServerFields(
          task: 'text-to-speech',
          initialBaseUrl: current.isEmpty ? whisperUrl : current,
          initialModel: _synthesis.selfHostedModel,
          initialVoice: _synthesis.selfHostedVoice,
          showVoicePicker: true,
          onBaseUrlChanged: (value) {
            _synthesis.selfHostedBaseUrl = value;
            _settings.put('tts_base_url', value);
          },
          onModelChanged: (value) {
            _synthesis.selfHostedModel = value;
            _settings.put('tts_model', value);
          },
          onVoiceChanged: (value) {
            _synthesis.selfHostedVoice = value;
            _settings.put('tts_voice', value);
          },
        ),
        const SizedBox(height: 8),
        _PersistedField(
          label: 'API key (optional)',
          hint: 'Only if your server requires one',
          obscure: true,
          secureStorageKey: 'tts_api_key',
          onChanged: (value) => _synthesis.selfHostedKey = value,
        ),
      ],
    );
  }

  Widget _elevenLabsKeyField() {
    return _PersistedField(
      label: 'ElevenLabs API Key',
      hint: 'sk_...',
      obscure: true,
      secureStorageKey: 'elevenlabs_api_key',
      onChanged: (value) {
        // One account, one key — shared with Scribe.
        _synthesis.elevenLabsKey = value;
        _scribe.apiKey = value;
      },
      onCommitted: (value) async {
        if (value.isNotEmpty) await _loadElevenLabsVoices();
      },
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

  Widget _elevenLabsVoicePicker() {
    final theme = Theme.of(context);
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

    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: hasCurrent ? currentId : _elevenLabsVoices.first.id,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Voice',
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
          ),
        ),
        const SizedBox(width: 8),
        _previewButton(SpeechEngine.elevenLabs, _synthesis.elevenLabsVoiceId),
      ],
    );
  }

  /// Play button for auditioning a voice. Shared by the ElevenLabs picker and
  /// the device-voice row; the self-hosted one lives in SpeechServerFields
  /// because it needs the address and model as currently typed.
  Widget _previewButton(SpeechEngine engine, String? voice, {String? locale}) {
    if (_previewingVoice) {
      return const Padding(
        padding: EdgeInsets.all(12.0),
        child: SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton.filledTonal(
      icon: const Icon(Icons.play_arrow),
      tooltip: 'Hear this voice',
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        setState(() => _previewingVoice = true);
        final ok = await _synthesis.previewVoice(
          engine: engine,
          voice: voice,
          localeOverride: locale,
        );
        if (!mounted) return;
        setState(() => _previewingVoice = false);
        if (!ok) {
          messenger.showSnackBar(const SnackBar(
            content: Text('Could not play a preview.'),
          ));
        }
      },
    );
  }

  Widget _rateSlider() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Speaking rate — ${_synthesis.rate.toStringAsFixed(2)}×',
          style: Theme.of(context).textTheme.titleSmall,
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
}

/// Text field that applies as you type and persists on the way out.
///
/// Pasting a key and closing the page without pressing anything is how the
/// SerpAPI key got silently dropped in v3.6.2; with five credentials on this
/// page now, it's not worth repeating per field.
class _PersistedField extends StatefulWidget {
  final String label;
  final String? hint;
  final bool obscure;
  final String? initialValue;

  /// Secure-storage key. When set, the value is loaded from and written to
  /// secure storage instead of the caller managing it.
  final String? secureStorageKey;

  final void Function(String value) onChanged;
  final Future<void> Function(String value)? onCommitted;

  const _PersistedField({
    required this.label,
    required this.onChanged,
    this.hint,
    this.obscure = false,
    this.initialValue,
    this.secureStorageKey,
    this.onCommitted,
  });

  @override
  State<_PersistedField> createState() => _PersistedFieldState();
}

class _PersistedFieldState extends State<_PersistedField> {
  final _controller = TextEditingController();
  bool _obscured = true;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.secureStorageKey != null) {
      try {
        _controller.text =
            await _storage.read(key: widget.secureStorageKey!) ?? '';
      } catch (_) {
        // No keyring; in-memory only for this session.
      }
    } else {
      _controller.text = widget.initialValue ?? '';
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _commit() async {
    final value = _controller.text.trim();
    final key = widget.secureStorageKey;
    if (key != null) {
      try {
        if (value.isEmpty) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: value);
        }
      } catch (_) {}
    }
    widget.onChanged(value);
    await widget.onCommitted?.call(value);
  }

  @override
  void dispose() {
    // Fire-and-forget: the widget is going away, so there's nothing to await.
    final value = _controller.text.trim();
    final key = widget.secureStorageKey;
    if (key != null && value.isNotEmpty) {
      _storage.write(key: key, value: value).catchError((_) {});
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      enabled: _ready,
      obscureText: widget.obscure && _obscured,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        border: const OutlineInputBorder(),
        suffixIcon: widget.obscure
            ? IconButton(
                icon: Icon(
                  _obscured ? Icons.visibility : Icons.visibility_off,
                ),
                onPressed: () => setState(() => _obscured = !_obscured),
              )
            : null,
      ),
      onChanged: widget.onChanged,
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) {
        FocusManager.instance.primaryFocus?.unfocus();
        _commit();
      },
    );
  }
}
