import 'package:flutter/material.dart';

import 'package:horizon/Services/network_discovery_service.dart';
import 'package:horizon/Services/voice/stt/speech_model_catalogue.dart';

/// Server address, network scan, and model/voice pickers for a speech server.
///
/// Shared by the transcription and synthesis sections because they point at
/// the same kind of server — usually literally the same one, since Speaches
/// serves both. Model and voice are **pickers populated from the server**
/// rather than text fields: a model id like
/// `deepdml/faster-whisper-large-v3-turbo-ct2` is miserable to type on a
/// phone, and one wrong character fails at the moment you try to speak rather
/// than when you enter it.
class SpeechServerFields extends StatefulWidget {
  /// `automatic-speech-recognition` or `text-to-speech`.
  final String task;

  final String initialBaseUrl;
  final String initialModel;

  /// Only meaningful for text-to-speech.
  final String initialVoice;
  final bool showVoicePicker;

  final ValueChanged<String> onBaseUrlChanged;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String>? onVoiceChanged;

  const SpeechServerFields({
    super.key,
    required this.task,
    required this.initialBaseUrl,
    required this.initialModel,
    required this.onBaseUrlChanged,
    required this.onModelChanged,
    this.initialVoice = '',
    this.showVoicePicker = false,
    this.onVoiceChanged,
  });

  @override
  State<SpeechServerFields> createState() => _SpeechServerFieldsState();
}

class _SpeechServerFieldsState extends State<SpeechServerFields> {
  late final TextEditingController _address;
  late String _model;
  late String _voice;

  List<SpeechServerModel> _models = const [];
  bool _loading = false;
  bool _scanning = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(text: widget.initialBaseUrl);
    _model = widget.initialModel;
    _voice = widget.initialVoice;
    if (_address.text.trim().isNotEmpty) _loadModels();
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  List<SpeechServerModel> get _relevant =>
      _models.where((m) => m.task == widget.task).toList();

  SpeechServerModel? get _selected {
    for (final model in _relevant) {
      if (model.id == _model) return model;
    }
    return null;
  }

  Future<void> _loadModels() async {
    final base = _address.text.trim();
    if (base.isEmpty) return;
    setState(() {
      _loading = true;
      _status = null;
    });

    final models = await SpeechModelCatalogue.fetch(base);
    if (!mounted) return;

    setState(() {
      _models = models;
      _loading = false;
      final relevant = _relevant;
      if (relevant.isEmpty) {
        _status = models.isEmpty
            ? "Couldn't read a model list from that address."
            : 'That server has no ${_taskLabel} model installed.';
      } else {
        _status = null;
        // Adopt the only sensible option rather than leaving the field
        // pointing at a model this server doesn't have.
        if (_selected == null) {
          _model = relevant.first.id;
          widget.onModelChanged(_model);
          _syncVoiceToModel();
        }
      }
    });
  }

  String get _taskLabel =>
      widget.task == 'text-to-speech' ? 'speech' : 'transcription';

  void _syncVoiceToModel() {
    final voices = _selected?.voices ?? const [];
    if (voices.isEmpty) return;
    if (!voices.contains(_voice)) {
      _voice = voices.first;
      widget.onVoiceChanged?.call(_voice);
    }
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _status = 'Scanning the network…';
    });

    final found = await NetworkDiscoveryService.discover(
      services: [DiscoverableService.speaches],
    );
    if (!mounted) return;

    if (found.isEmpty) {
      setState(() {
        _scanning = false;
        _status = 'No speech server found on this network.';
      });
      return;
    }

    _address.text = found.first.baseUrl;
    widget.onBaseUrlChanged(_address.text);
    setState(() => _scanning = false);
    await _loadModels();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final relevant = _relevant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _address,
          decoration: InputDecoration(
            labelText: 'Server address',
            hintText: 'http://172.16.23.20:8001',
            border: const OutlineInputBorder(),
            suffixIcon: _scanning
                ? const Padding(
                    padding: EdgeInsets.all(12.0),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.wifi_find),
                    tooltip: 'Find it on this network',
                    onPressed: _scan,
                  ),
          ),
          onChanged: widget.onBaseUrlChanged,
          onSubmitted: (_) => _loadModels(),
          onTapOutside: (_) {
            FocusManager.instance.primaryFocus?.unfocus();
            _loadModels();
          },
        ),
        const SizedBox(height: 8),

        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8.0),
            child: LinearProgressIndicator(),
          )
        else if (relevant.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: _selected?.id ?? relevant.first.id,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
            ),
            items: relevant
                .map((m) => DropdownMenuItem(
                      value: m.id,
                      child: Text(m.shortName, overflow: TextOverflow.ellipsis),
                    ))
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() {
                _model = value;
                _syncVoiceToModel();
              });
              widget.onModelChanged(value);
            },
          )
        else
          // Fallback so a server that won't list models is still usable.
          TextField(
            controller: TextEditingController(text: _model),
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
              helperText: 'Enter it manually — the model list was unavailable',
            ),
            onChanged: widget.onModelChanged,
          ),

        if (widget.showVoicePicker) ...[
          const SizedBox(height: 8),
          _voiceField(theme),
        ],

        if (_status != null)
          Padding(
            padding: const EdgeInsets.only(top: 6.0),
            child: Text(
              _status!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
  }

  Widget _voiceField(ThemeData theme) {
    final voices = _selected?.voices ?? const [];
    if (voices.isEmpty) {
      return TextField(
        controller: TextEditingController(text: _voice),
        decoration: const InputDecoration(
          labelText: 'Voice',
          border: OutlineInputBorder(),
          helperText: 'This server does not list its voices',
        ),
        onChanged: (value) => widget.onVoiceChanged?.call(value),
      );
    }

    return DropdownButtonFormField<String>(
      initialValue: voices.contains(_voice) ? _voice : voices.first,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Voice',
        border: OutlineInputBorder(),
      ),
      items: voices
          .map((v) => DropdownMenuItem(value: v, child: Text(v)))
          .toList(),
      onChanged: (value) {
        if (value == null) return;
        setState(() => _voice = value);
        widget.onVoiceChanged?.call(value);
      },
    );
  }
}
