import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

/// Transcribes via ElevenLabs Scribe.
///
/// Uses the batch endpoint rather than the realtime WebSocket: a spoken turn
/// is a few seconds of audio that's already been captured by the time we get
/// here, so streaming would add a socket lifecycle for no latency the user
/// would notice. Realtime earns its keep for live captions, not for this.
class ElevenLabsTranscriber implements RecordedAudioTranscriber {
  /// Shares the key with text-to-speech — one ElevenLabs account, one key.
  String apiKey;

  /// Scribe model id.
  String model;

  ElevenLabsTranscriber({String? apiKey, String? model})
      : apiKey = apiKey ?? '',
        model = model ?? 'scribe_v1';

  static const Duration _timeout = Duration(seconds: 60);

  @override
  bool get isConfigured => apiKey.trim().isNotEmpty;

  @override
  String? get configurationHint =>
      isConfigured ? null : 'Add your ElevenLabs API key.';

  @override
  Future<SttResult> transcribe(String path, {String? languageCode}) async {
    if (!isConfigured) {
      return const SttResult.failure(
        'No ElevenLabs key is set. Add one in Settings → Voice.',
      );
    }

    final file = File(path);
    if (!await file.exists()) {
      return const SttResult.failure('The recording disappeared before upload.');
    }

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.https('api.elevenlabs.io', '/v1/speech-to-text'),
      );
      request.headers['xi-api-key'] = apiKey.trim();
      request.fields['model_id'] = model.trim().isEmpty ? 'scribe_v1' : model.trim();
      if (languageCode != null && languageCode.isNotEmpty) {
        request.fields['language_code'] =
            languageCode.split(RegExp('[-_]')).first;
      }
      request.files.add(await http.MultipartFile.fromPath('file', path));

      final streamed = await HorizonHttp.client.send(request).timeout(_timeout);
      final body = await streamed.stream.bytesToString();

      if (streamed.statusCode != 200) {
        return SttResult.failure(
          'ElevenLabs: ${HttpErrorFormatter.formatHttpError(streamed.statusCode, body: body)}',
        );
      }

      final decoded = json.decode(body);
      final text = decoded is Map ? (decoded['text'] ?? '').toString() : '';
      return SttResult(text.trim());
    } on TimeoutException {
      return const SttResult.failure(
        'ElevenLabs did not answer within 60 s.',
      );
    } on SocketException catch (e) {
      return SttResult.failure(
        'Could not reach ElevenLabs: ${HttpErrorFormatter.formatException(e)}',
      );
    } on http.ClientException catch (e) {
      return SttResult.failure(
        'Could not reach ElevenLabs: ${HttpErrorFormatter.formatException(e)}',
      );
    } catch (e) {
      return SttResult.failure('Transcription failed: $e');
    }
  }
}
