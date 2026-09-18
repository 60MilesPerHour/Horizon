import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

/// Transcribes via the OpenAI-compatible `/v1/audio/transcriptions` endpoint.
///
/// That one endpoint covers every self-hosted Whisper server worth running —
/// faster-whisper-server, Speaches, whisper.cpp's `server`, LocalAI — and
/// also OpenAI and Groq if the base URL and key point there. Which is why
/// this is a base URL and a model name rather than a list of named providers.
class WhisperTranscriber implements RecordedAudioTranscriber {
  /// Server root, e.g. `http://172.16.23.20:8000`. The `/v1/...` path is
  /// appended, matching how the Ollama and OpenRouter services are configured.
  String baseUrl;

  /// Model name the server expects. `whisper-1` is what OpenAI calls it;
  /// self-hosted servers usually want something like
  /// `Systran/faster-distil-whisper-large-v3`.
  String model;

  /// Optional bearer token. Self-hosted servers usually need none; OpenAI and
  /// Groq require one.
  String apiKey;

  WhisperTranscriber({
    String? baseUrl,
    String? model,
    String? apiKey,
  })  : baseUrl = baseUrl ?? '',
        model = model ?? 'whisper-1',
        apiKey = apiKey ?? '';

  /// Transcription of a short clip on a warm GPU is fast; a cold model load
  /// is not, and neither is a CPU-only server.
  static const Duration _timeout = Duration(seconds: 90);

  @override
  bool get isConfigured => baseUrl.trim().isNotEmpty;

  @override
  String? get configurationHint => isConfigured
      ? null
      : 'Set the server address, e.g. http://172.16.23.20:8000';

  /// Resolved transcription endpoint for the configured [baseUrl].
  Uri endpoint() {
    var base = baseUrl.trim();
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'http://$base';
    }
    base = base.replaceAll(RegExp(r'/+$'), '');
    // Tolerate a base that already includes /v1, since that's how these
    // servers are usually written down.
    if (base.endsWith('/v1')) {
      return Uri.parse('$base/audio/transcriptions');
    }
    return Uri.parse('$base/v1/audio/transcriptions');
  }

  @override
  Future<SttResult> transcribe(String path, {String? languageCode}) async {
    if (!isConfigured) {
      return SttResult.failure(
        'No Whisper server address is set. Add one in Settings → Voice.',
      );
    }

    final file = File(path);
    if (!await file.exists()) {
      return const SttResult.failure('The recording disappeared before upload.');
    }

    try {
      final request = http.MultipartRequest('POST', endpoint());
      if (apiKey.trim().isNotEmpty) {
        request.headers['Authorization'] = 'Bearer ${apiKey.trim()}';
      }
      request.fields['model'] = model.trim().isEmpty ? 'whisper-1' : model.trim();
      request.fields['response_format'] = 'json';
      if (languageCode != null && languageCode.isNotEmpty) {
        // The API wants a bare ISO-639-1 code, but Horizon stores recogniser
        // locales in `en_US` / `en-GB` form.
        request.fields['language'] = languageCode.split(RegExp('[-_]')).first;
      }
      request.files.add(await http.MultipartFile.fromPath('file', path));

      final streamed = await HorizonHttp.client.send(request).timeout(_timeout);
      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode != 200) {
        return SttResult.failure(
          'Whisper server: ${HttpErrorFormatter.formatHttpError(streamed.statusCode, body: body)}',
        );
      }

      final decoded = json.decode(body);
      final text = decoded is Map ? (decoded['text'] ?? '').toString() : '';
      return SttResult(text.trim());
    } on TimeoutException {
      return SttResult.failure(
        'The Whisper server did not answer within ${_timeout.inSeconds} s. '
        'A cold model load can take a while — try again.',
      );
    } on SocketException catch (e) {
      return SttResult.failure(
        'Could not reach the Whisper server: ${HttpErrorFormatter.formatException(e)}',
      );
    } on http.ClientException catch (e) {
      return SttResult.failure(
        'Could not reach the Whisper server: ${HttpErrorFormatter.formatException(e)}',
      );
    } catch (e) {
      return SttResult.failure('Transcription failed: $e');
    }
  }
}
