import 'dart:convert';

import 'package:horizon/Utils/horizon_http.dart';

/// One model offered by a speech server.
class SpeechServerModel {
  final String id;

  /// `automatic-speech-recognition` or `text-to-speech`, as reported by the
  /// server.
  final String task;

  /// Voices this model provides, for text-to-speech. Empty when the server
  /// doesn't say.
  final List<String> voices;

  const SpeechServerModel({
    required this.id,
    required this.task,
    this.voices = const [],
  });

  bool get isTranscription => task == 'automatic-speech-recognition';
  bool get isSynthesis => task == 'text-to-speech';

  /// Last path segment — `Kokoro-82M-v1.0-ONNX` rather than the full
  /// `speaches-ai/Kokoro-82M-v1.0-ONNX`, for a dropdown that has to fit on a
  /// phone.
  String get shortName => id.contains('/') ? id.split('/').last : id;
}

/// Reads the model list off a Speaches-compatible server.
///
/// Exists so the model fields can be pickers rather than free text. Typing
/// `deepdml/faster-whisper-large-v3-turbo-ct2` by hand on a phone is both
/// tedious and silently unforgiving — one wrong character produces a 404 at
/// the moment you try to speak, not when you enter it.
class SpeechModelCatalogue {
  static const Duration _timeout = Duration(seconds: 12);

  /// Fetches the installed models. Returns an empty list on any failure, so a
  /// picker degrades to the free-text fallback rather than blocking setup.
  static Future<List<SpeechServerModel>> fetch(
    String baseUrl, {
    String apiKey = '',
  }) async {
    final uri = _endpoint(baseUrl);
    if (uri == null) return const [];

    try {
      final response = await HorizonHttp.client.get(
        uri,
        headers: {
          if (apiKey.trim().isNotEmpty)
            'Authorization': 'Bearer ${apiKey.trim()}',
        },
      ).timeout(_timeout);
      if (response.statusCode != 200) return const [];

      final body = json.decode(utf8.decode(response.bodyBytes));
      final entries = body is Map ? body['data'] : body;
      if (entries is! List) return const [];

      final models = <SpeechServerModel>[];
      for (final entry in entries) {
        if (entry is! Map) continue;
        final id = (entry['id'] ?? '').toString();
        if (id.isEmpty) continue;
        models.add(SpeechServerModel(
          id: id,
          task: (entry['task'] ?? '').toString(),
          voices: _voicesOf(entry),
        ));
      }
      models.sort((a, b) => a.id.compareTo(b.id));
      return models;
    } catch (_) {
      return const [];
    }
  }

  /// Voice names, which Speaches reports per TTS model. Shapes vary between
  /// versions — a list of strings, or of objects with a name — so both are
  /// accepted rather than assuming one.
  static List<String> _voicesOf(Map entry) {
    final raw = entry['voices'] ?? entry['voice_ids'] ?? entry['speakers'];
    if (raw is! List) return const [];
    final names = <String>[];
    for (final voice in raw) {
      if (voice is String && voice.isNotEmpty) {
        names.add(voice);
      } else if (voice is Map) {
        final name = (voice['name'] ?? voice['id'] ?? '').toString();
        if (name.isNotEmpty) names.add(name);
      }
    }
    return names;
  }

  /// Same leniency as the transcriber and synthesiser: missing scheme,
  /// trailing slash, or a base already ending in `/v1`.
  static Uri? _endpoint(String baseUrl) {
    var base = baseUrl.trim();
    if (base.isEmpty) return null;
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'http://$base';
    }
    base = base.replaceAll(RegExp(r'/+$'), '');
    final path = base.endsWith('/v1') ? '$base/models' : '$base/v1/models';
    return Uri.tryParse(path);
  }
}
