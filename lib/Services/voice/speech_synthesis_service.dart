import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Utils/remote_endpoint.dart';

/// Which engine speaks the assistant's replies.
enum SpeechEngine {
  /// The device's own TTS. Free, offline, instant — and robotic.
  system,

  /// A self-hosted server speaking OpenAI's `/v1/audio/speech` — Speaches
  /// (Kokoro/Piper), or anything else with that endpoint. Free, no keys, and
  /// usually the same box already answering transcription requests.
  selfHosted,

  /// ElevenLabs. Needs a key and network, sounds dramatically better.
  elevenLabs;

  static SpeechEngine fromString(String? value) {
    switch (value) {
      case 'elevenlabs':
        return SpeechEngine.elevenLabs;
      case 'selfhosted':
        return SpeechEngine.selfHosted;
      default:
        return SpeechEngine.system;
    }
  }

  String get storageValue {
    switch (this) {
      case SpeechEngine.elevenLabs:
        return 'elevenlabs';
      case SpeechEngine.selfHosted:
        return 'selfhosted';
      case SpeechEngine.system:
        return 'system';
    }
  }

  String get label {
    switch (this) {
      case SpeechEngine.elevenLabs:
        return 'ElevenLabs';
      case SpeechEngine.selfHosted:
        return 'Self-hosted';
      case SpeechEngine.system:
        return 'Device voice';
    }
  }

  /// Whether this engine returns audio bytes over HTTP, as opposed to the
  /// platform speaking the text itself. Decides whether the queue needs to
  /// prefetch and play clips.
  bool get isRemote => this != SpeechEngine.system;
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

  /// Self-hosted `/v1/audio/speech` server root, e.g. `http://172.16.23.20:8000`.
  /// Where the speech server lives, at home and away. See
  /// [WhisperTranscriber.endpoint] — same server, same problem: one LAN
  /// address meant spoken replies fell back to the device voice off the
  /// network, which sounds like the self-hosted voice having broken.
  final RemoteEndpoint selfHosted;

  /// Model the self-hosted server expects, e.g.
  /// `speaches-ai/Kokoro-82M-v1.0-ONNX`.
  String selfHostedModel;

  /// Voice name, e.g. `af_heart` for Kokoro.
  String selfHostedVoice;

  /// Optional bearer token for the self-hosted server. Usually unset.
  String selfHostedKey;

  /// Playback/speech rate. 1.0 is the engine default.
  double rate;

  SpeechSynthesisService({
    SpeechEngine? engine,
    String? elevenLabsKey,
    String? elevenLabsVoiceId,
    String? systemVoiceLocale,
    String? selfHostedBaseUrl,
    String? selfHostedBackupUrl,
    String? cfAccessClientId,
    String? cfAccessClientSecret,
    String? selfHostedModel,
    String? selfHostedVoice,
    String? selfHostedKey,
    double? rate,
  })  : selfHosted = RemoteEndpoint(
          primary: selfHostedBaseUrl,
          backup: selfHostedBackupUrl,
          cfAccessClientId: cfAccessClientId,
          cfAccessClientSecret: cfAccessClientSecret,
        ),
        engine = engine ?? SpeechEngine.system,
        elevenLabsKey = elevenLabsKey ?? '',
        elevenLabsVoiceId = elevenLabsVoiceId ?? _defaultVoiceId,
        systemVoiceLocale = systemVoiceLocale ?? '',
        selfHostedModel = selfHostedModel ?? defaultSelfHostedModel,
        selfHostedVoice = selfHostedVoice ?? defaultSelfHostedVoice,
        selfHostedKey = selfHostedKey ?? '',
        rate = rate ?? 1.0;

  /// Settings mutates the addresses through these so the sticky choice of
  /// which one last answered is dropped with the value it referred to.
  String get selfHostedBaseUrl => selfHosted.primary;
  set selfHostedBaseUrl(String value) {
    selfHosted.primary = value;
    selfHosted.reset();
  }

  String get selfHostedBackupUrl => selfHosted.backup;
  set selfHostedBackupUrl(String value) {
    selfHosted.backup = value;
    selfHosted.reset();
  }

  /// Speaches' Kokoro build, the usual reason to run one of these at all.
  static const String defaultSelfHostedModel =
      'speaches-ai/Kokoro-82M-v1.0-ONNX';

  /// Kokoro's default American female voice.
  static const String defaultSelfHostedVoice = 'af_heart';

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

  /// Bumped by [stop]. A drain loop captures it and abandons itself the moment
  /// it changes, which is what stops barge-in producing two voices: without
  /// it, stop() clearing `_speaking` lets the next enqueue start a second
  /// drain while the first is still parked on an await inside playback.
  int _generation = 0;

  /// Whether audio is currently coming out of the device.
  bool get isSpeaking => _speaking;

  /// The engine that will actually be used, accounting for missing config.
  /// Falling back to the device voice means a missing key is a worse-sounding
  /// answer rather than a silent one.
  SpeechEngine get effectiveEngine {
    switch (engine) {
      case SpeechEngine.elevenLabs:
        return isElevenLabsConfigured
            ? SpeechEngine.elevenLabs
            : SpeechEngine.system;
      case SpeechEngine.selfHosted:
        return isSelfHostedConfigured
            ? SpeechEngine.selfHosted
            : SpeechEngine.system;
      case SpeechEngine.system:
        return SpeechEngine.system;
    }
  }

  bool get isElevenLabsConfigured => elevenLabsKey.trim().isNotEmpty;

  bool get isSelfHostedConfigured => selfHosted.isConfigured;

  /// Resolved `/v1/audio/speech` endpoint. Tolerates a missing scheme, a
  /// trailing slash, and a base that already ends in `/v1` — the same
  /// leniency the Whisper transcriber needs, and for the same reason: these
  /// servers get written down both ways.
  Uri? selfHostedEndpoint({String? override}) {
    final candidates = selfHosted.candidates();
    final base = override ?? (candidates.isEmpty ? null : candidates.first);
    if (base == null || base.trim().isEmpty) return null;
    return RemoteEndpoint.resolve(base, '/v1/audio/speech');
  }

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
    _generation++;
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
    final generation = _generation;

    try {
      while (_queue.isNotEmpty && !_stopped && generation == _generation) {
        final chunk = _queue.removeAt(0);

        if (effectiveEngine.isRemote) {
          // Take whatever was prefetched for this chunk, then immediately
          // start fetching the next one so the network round-trip overlaps
          // with playback instead of adding to it.
          final pending = _prefetch;
          _prefetch = null;
          final bytes = await (pending ?? _synthesizeRemote(chunk));
          if (_stopped || generation != _generation) return;

          if (_queue.isNotEmpty) {
            _prefetch = _synthesizeRemote(_queue.first);
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
      // Only the current owner may clear the flag; a superseded loop
      // unwinding must not mark a live one as finished.
      if (generation == _generation) _speaking = false;
    }
  }

  Future<void> _speakSystem(String text) async {
    final generation = _generation;
    await _configureSystemTts();
    if (_stopped || generation != _generation) return;
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

  /// Short line used to audition a voice.
  ///
  /// Deliberately a sentence with varied vowels and a comma rather than
  /// "test": prosody and pacing are most of what distinguishes one voice from
  /// another, and a single word reveals neither.
  static const String previewPhrase =
      "Hello — this is how I sound when I read your replies aloud.";

  /// Speaks [previewPhrase] in a specific voice, without changing the
  /// configured one.
  ///
  /// Auditioning matters here because Kokoro ships around fifty voices and
  /// ElevenLabs accounts carry their own; choosing from a dropdown of names
  /// is guesswork otherwise. Returns false when nothing could be produced,
  /// so the UI can say so instead of appearing to do nothing.
  Future<bool> previewVoice({
    required SpeechEngine engine,
    String? voice,
    String? model,
    String? baseUrl,
    String? localeOverride,
  }) async {
    // Stop whatever is queued first: overlapping a preview with a reply being
    // read out makes both unintelligible.
    await stop();
    _stopped = false;

    switch (engine) {
      case SpeechEngine.selfHosted:
        final bytes = await _synthesizeSelfHosted(
          previewPhrase,
          voice: voice,
          model: model,
          baseUrl: baseUrl,
        );
        if (bytes == null) return false;
        await _playBytes(bytes);
        return true;

      case SpeechEngine.elevenLabs:
        final bytes = await _synthesizeElevenLabs(
          previewPhrase,
          voiceOverride: voice,
        );
        if (bytes == null) return false;
        await _playBytes(bytes);
        return true;

      case SpeechEngine.system:
        try {
          await _configureSystemTts();
          if (localeOverride != null && localeOverride.isNotEmpty) {
            await _systemTts.setLanguage(localeOverride);
            // The override is transient; restore what's configured so a
            // preview can't silently change the voice used for real replies.
            _systemTtsConfigured = false;
          }
          await _systemTts.speak(previewPhrase);
          return true;
        } catch (_) {
          return false;
        }
    }
  }

  /// Dispatches to whichever remote engine is active.
  Future<Uint8List?> _synthesizeRemote(String text) {
    switch (effectiveEngine) {
      case SpeechEngine.elevenLabs:
        return _synthesizeElevenLabs(text);
      case SpeechEngine.selfHosted:
        return _synthesizeSelfHosted(text);
      case SpeechEngine.system:
        return Future.value(null);
    }
  }

  /// OpenAI's `/v1/audio/speech` shape, which Speaches implements verbatim.
  Future<Uint8List?> _synthesizeSelfHosted(
    String text, {
    String? voice,
    String? model,
    String? baseUrl,
  }) async {
    if (baseUrl == null && !isSelfHostedConfigured) return null;

    Future<Uint8List?> post(String base) async {
      final response = await HorizonHttp.client
          .post(
            RemoteEndpoint.resolve(base, '/v1/audio/speech'),
            headers: {
              'content-type': 'application/json',
              ...selfHosted.headersFor(base, bearerToken: selfHostedKey),
            },
            body: json.encode({
              'model': (model ?? selfHostedModel).trim().isEmpty
                  ? defaultSelfHostedModel
                  : (model ?? selfHostedModel).trim(),
              'voice': (voice ?? selfHostedVoice).trim().isEmpty
                  ? defaultSelfHostedVoice
                  : (voice ?? selfHostedVoice).trim(),
              'input': text,
              // Speaches supports mp3 and wav but not opus or aac; mp3 is the
              // smaller of the two over the wire.
              'response_format': 'mp3',
              'speed': rate.clamp(0.5, 2.0),
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) return null;
      if (response.bodyBytes.isEmpty) return null;
      // An Access login page is a 200 with an HTML body, and handing that to
      // the audio player produces silence rather than an error.
      if (selfHosted.describeAccessBlock(
              utf8.decode(response.bodyBytes.take(512).toList(),
                  allowMalformed: true),
              base) !=
          null) {
        return null;
      }
      return response.bodyBytes;
    }

    try {
      // A preview aims at exactly the address being auditioned; a real
      // utterance is free to fall over to the remote one.
      if (baseUrl != null) return await post(baseUrl);
      return await selfHosted.withFailover(post);
    } catch (_) {
      // Falls through to the device voice for this sentence.
      return null;
    }
  }

  Future<Uint8List?> _synthesizeElevenLabs(
    String text, {
    String? voiceOverride,
  }) async {
    if (elevenLabsKey.isEmpty) return null;
    final requested = voiceOverride ?? elevenLabsVoiceId;
    final voice = requested.isEmpty ? _defaultVoiceId : requested;
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
