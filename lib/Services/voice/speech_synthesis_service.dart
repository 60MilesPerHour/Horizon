import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:horizon/Utils/horizon_http.dart';

/// Which engine speaks the assistant's replies.
enum SpeechEngine {
  /// The device's own TTS. Free, offline, instant — and robotic.
  system,

  /// ElevenLabs. Needs a key and network, sounds dramatically better.
  elevenLabs;

  static SpeechEngine fromString(String? value) =>
      value == 'elevenlabs' ? SpeechEngine.elevenLabs : SpeechEngine.system;

  String get storageValue =>
      this == SpeechEngine.elevenLabs ? 'elevenlabs' : 'system';

  String get label =>
      this == SpeechEngine.elevenLabs ? 'ElevenLabs' : 'Device voice';
}

/// One named voice offered by an engine.
class SpeechVoice {
  final String id;
  final String name;

  const SpeechVoice({required this.id, required this.name});
}

/// Speaks text aloud, one chunk at a time, in order.
///
/// Replies are spoken sentence by sentence as they stream in rather than after
/// the whole answer arrives — a model that takes twenty seconds to finish
/// would otherwise leave the user staring at a silent screen. [enqueue] is
/// called with each completed sentence and the queue plays them back to back;
/// with ElevenLabs the next clip is fetched while the current one plays, so
/// the gap between sentences stays short.
class SpeechSynthesisService {
  SpeechEngine engine;

  /// ElevenLabs API key. Empty means the engine falls back to system TTS
  /// rather than failing silently.
  String elevenLabsKey;

  /// ElevenLabs voice id. Defaults to Rachel, a stock voice present on every
  /// account, so a fresh key works with no further setup.
  String elevenLabsVoiceId;

  /// System TTS voice/locale, e.g. `en-GB`. Empty uses the device default.
  String systemVoiceLocale;

  /// Playback/speech rate. 1.0 is the engine default.
  double rate;

  SpeechSynthesisService({
    SpeechEngine? engine,
    String? elevenLabsKey,
    String? elevenLabsVoiceId,
    String? systemVoiceLocale,
    double? rate,
  })  : engine = engine ?? SpeechEngine.system,
        elevenLabsKey = elevenLabsKey ?? '',
        elevenLabsVoiceId = elevenLabsVoiceId ?? _defaultVoiceId,
        systemVoiceLocale = systemVoiceLocale ?? '',
        rate = rate ?? 1.0;

  /// ElevenLabs' "Rachel" — a stock voice on every account.
  static const String _defaultVoiceId = '21m00Tcm4TlvDq8ikWAM';

  /// Low-latency model; the quality difference against the multilingual v2
  /// model is small next to the difference in how long the user waits.
  static const String _elevenLabsModel = 'eleven_turbo_v2_5';

  final FlutterTts _systemTts = FlutterTts();

  /// Created on first use. Constructing an AudioPlayer initialises the
  /// platform audio plugin, which is pure cost for anyone on the device voice.
  AudioPlayer? _playerInstance;
  AudioPlayer get _player => _playerInstance ??= AudioPlayer();

  bool _systemTtsConfigured = false;

  /// Pending chunks, in the order they should be spoken.
  final List<String> _queue = [];

  /// In-flight or completed synthesis for queued chunks, keyed by chunk text
  /// position — populated one ahead so playback isn't gated on the request.
  Future<Uint8List?>? _prefetch;

  bool _speaking = false;
  bool _stopped = false;

  /// Whether audio is currently coming out of the device.
  bool get isSpeaking => _speaking;

  /// The engine that will actually be used, accounting for a missing key.
  SpeechEngine get effectiveEngine =>
      engine == SpeechEngine.elevenLabs && elevenLabsKey.isEmpty
          ? SpeechEngine.system
          : engine;

  bool get isElevenLabsConfigured => elevenLabsKey.isNotEmpty;

  /// Queues [text] to be spoken. Returns immediately.
  void enqueue(String text) {
    final trimmed = cleanForSpeech(text);
    if (trimmed.isEmpty) return;
    _stopped = false;
    _queue.add(trimmed);
    unawaited(_drain());
  }

  /// Speaks [text] on its own, cancelling anything queued. Used for short
  /// interjections like an error the user needs to hear.
  Future<void> speakNow(String text) async {
    await stop();
    enqueue(text);
  }

  /// Stops playback and drops the queue. Called on barge-in — the user
  /// talking over the assistant should cut it off mid-word, not be made to
  /// wait for the sentence to finish.
  Future<void> stop() async {
    _stopped = true;
    _queue.clear();
    _prefetch = null;
    _speaking = false;
    try {
      await _systemTts.stop();
    } catch (_) {}
    try {
      await _playerInstance?.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _playerInstance?.dispose();
    _playerInstance = null;
  }

  Future<void> _drain() async {
    if (_speaking) return;
    _speaking = true;

    try {
      while (_queue.isNotEmpty && !_stopped) {
        final chunk = _queue.removeAt(0);

        if (effectiveEngine == SpeechEngine.elevenLabs) {
          // Take whatever was prefetched for this chunk, then immediately
          // start fetching the next one so the network round-trip overlaps
          // with playback instead of adding to it.
          final pending = _prefetch;
          _prefetch = null;
          final bytes = await (pending ?? _synthesizeElevenLabs(chunk));
          if (_stopped) return;

          if (_queue.isNotEmpty) {
            _prefetch = _synthesizeElevenLabs(_queue.first);
          }

          if (bytes != null) {
            await _playBytes(bytes);
            continue;
          }
          // Synthesis failed — say it with the device voice rather than
          // silently skipping a sentence of the answer.
        }

        await _speakSystem(chunk);
      }
    } finally {
      _speaking = false;
    }
  }

  Future<void> _speakSystem(String text) async {
    await _configureSystemTts();
    if (_stopped) return;
    try {
      // awaitSpeakCompletion (set below) makes this resolve when the utterance
      // finishes, which is what keeps the queue in order.
      await _systemTts.speak(text);
    } catch (_) {
      // A missing or broken TTS engine shouldn't take the session down; the
      // transcript is still on screen.
    }
  }

  Future<void> _configureSystemTts() async {
    if (_systemTtsConfigured) return;
    try {
      await _systemTts.awaitSpeakCompletion(true);
      await _systemTts.setSpeechRate(_systemRate);
      if (systemVoiceLocale.isNotEmpty) {
        await _systemTts.setLanguage(systemVoiceLocale);
      }
    } catch (_) {}
    _systemTtsConfigured = true;
  }

  /// flutter_tts takes 0.0–1.0 on Android where 0.5 is normal speed, but
  /// 0.0–1.0 with 1.0 normal on iOS/macOS. Horizon's [rate] is a multiplier
  /// of normal, so halve it on Android to land on the same perceived speed.
  double get _systemRate => (rate * 0.5).clamp(0.1, 1.0);

  /// Invalidates cached engine settings so a change in Settings takes effect
  /// on the next utterance instead of after a restart.
  void invalidateVoiceSettings() {
    _systemTtsConfigured = false;
  }

  Future<void> _playBytes(Uint8List bytes) async {
    try {
      await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
      // play() returns as soon as playback starts, so wait for the end or the
      // queue would all fire at once and talk over itself.
      await _player.onPlayerComplete.first;
    } catch (_) {
      // Fall through; the caller already handled a null synthesis.
    }
  }

  Future<Uint8List?> _synthesizeElevenLabs(String text) async {
    if (elevenLabsKey.isEmpty) return null;
    final voice = elevenLabsVoiceId.isEmpty ? _defaultVoiceId : elevenLabsVoiceId;
    final uri = Uri.https(
      'api.elevenlabs.io',
      '/v1/text-to-speech/$voice',
      {'output_format': 'mp3_44100_128'},
    );

    try {
      final response = await HorizonHttp.client
          .post(
            uri,
            headers: {
              'xi-api-key': elevenLabsKey,
              'content-type': 'application/json',
              'accept': 'audio/mpeg',
            },
            body: json.encode({
              'text': text,
              'model_id': _elevenLabsModel,
              'voice_settings': {
                'stability': 0.5,
                'similarity_boost': 0.75,
                'speed': rate.clamp(0.7, 1.2),
              },
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Lists the voices on the configured ElevenLabs account, or an empty list
  /// if the key is missing or the call fails.
  Future<List<SpeechVoice>> listElevenLabsVoices() async {
    if (elevenLabsKey.isEmpty) return const [];
    try {
      final response = await HorizonHttp.client.get(
        Uri.https('api.elevenlabs.io', '/v1/voices'),
        headers: {'xi-api-key': elevenLabsKey},
      ).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return const [];

      final body = json.decode(utf8.decode(response.bodyBytes));
      final voices = (body['voices'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((v) => SpeechVoice(
                id: (v['voice_id'] ?? '').toString(),
                name: (v['name'] ?? 'Voice').toString(),
              ))
          .where((v) => v.id.isNotEmpty)
          .toList();
      return voices;
    } catch (_) {
      return const [];
    }
  }

  /// Lists the device's own TTS languages.
  Future<List<SpeechVoice>> listSystemVoices() async {
    try {
      final languages = await _systemTts.getLanguages;
      if (languages is! List) return const [];
      return languages
          .map((l) => l.toString())
          .where((l) => l.isNotEmpty)
          .map((l) => SpeechVoice(id: l, name: l))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } catch (_) {
      return const [];
    }
  }

  /// Strips what shouldn't be read aloud. A spoken answer that recites
  /// "asterisk asterisk important asterisk asterisk" or reads a URL character
  /// by character is worse than one that just omits the markup.
  static String cleanForSpeech(String text) {
    var out = text.trim();
    if (out.isEmpty) return '';

    // Fenced code: say that there is code rather than reading the code.
    out = out.replaceAll(
      RegExp(r'```[\s\S]*?```'),
      ' (code block omitted) ',
    );
    // replaceAllMapped, not replaceAll: a String replacement is taken
    // literally, so `$1` would be spoken as "dollar one" rather than
    // expanding to the captured text.
    out = out.replaceAllMapped(
      RegExp(r'`([^`]*)`'),
      (match) => match.group(1) ?? '',
    );
    // Markdown links: keep the label, drop the target.
    out = out.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]*\)'),
      (match) => match.group(1) ?? '',
    );
    // Bare URLs.
    out = out.replaceAll(RegExp(r'https?://\S+'), 'a link');
    // Emphasis. Handled as matched pairs rather than by deleting every
    // `*_~`: a blanket strip turns OLLAMA_HOST into OLLAMAHOST and mangles
    // every snake_case identifier the model mentions.
    for (final pattern in [
      RegExp(r'\*\*\*(.+?)\*\*\*', dotAll: true),
      RegExp(r'\*\*(.+?)\*\*', dotAll: true),
      RegExp(r'\*(.+?)\*', dotAll: true),
      RegExp(r'~~(.+?)~~', dotAll: true),
      // Underscore emphasis only counts at a word boundary, which is what
      // separates _urgent_ from snake_case.
      RegExp(r'(?<![A-Za-z0-9_])__(.+?)__(?![A-Za-z0-9_])', dotAll: true),
      RegExp(r'(?<![A-Za-z0-9_])_(.+?)_(?![A-Za-z0-9_])', dotAll: true),
    ]) {
      out = out.replaceAllMapped(pattern, (match) => match.group(1) ?? '');
    }
    // Any unpaired marker left over would still be read out.
    out = out.replaceAll(RegExp(r'[*~]'), '');

    // Headings, list bullets and citation markers.
    out = out.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    out = out.replaceAll(RegExp(r'^\s*[-+*]\s+', multiLine: true), '');
    out = out.replaceAll(RegExp(r'\[\d+\]'), '');
    out = out.replaceAll(RegExp(r'[ \t]{2,}'), ' ');

    return out.trim();
  }
}
