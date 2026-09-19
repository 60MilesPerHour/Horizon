import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Utils/remote_endpoint.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

/// Transcribes via the OpenAI-compatible `/v1/audio/transcriptions` endpoint.
///
/// That one endpoint covers every self-hosted Whisper server worth running —
/// faster-whisper-server, Speaches, whisper.cpp's `server`, LocalAI — and
/// also OpenAI and Groq if the base URL and key point there. Which is why
/// this is a base URL and a model name rather than a list of named providers.
class WhisperTranscriber implements RecordedAudioTranscriber {
  /// Where the server lives, at home and away.
  ///
  /// Two addresses rather than one because a self-hosted speech server is
  /// reachable at an RFC1918 address on the LAN and, if it's behind a
  /// Cloudflare tunnel, at a hostname from anywhere. With only the first,
  /// transcription silently degraded to the device recogniser the moment you
  /// left the house — which reads as the feature being broken remotely.
  final RemoteEndpoint endpoint;

  /// Model name the server expects. `whisper-1` is what OpenAI calls it;
  /// self-hosted servers usually want something like
  /// `Systran/faster-distil-whisper-large-v3`.
  String model;

  /// Optional bearer token. Self-hosted servers usually need none; OpenAI and
  /// Groq require one.
  String apiKey;

  WhisperTranscriber({
    String? baseUrl,
    String? backupUrl,
    String? model,
    String? apiKey,
    String? cfAccessClientId,
    String? cfAccessClientSecret,
  })  : endpoint = RemoteEndpoint(
          primary: baseUrl,
          backup: backupUrl,
          cfAccessClientId: cfAccessClientId,
          cfAccessClientSecret: cfAccessClientSecret,
        ),
        model = model ?? 'whisper-1',
        apiKey = apiKey ?? '';

  /// Settings edits the addresses through these, so the sticky choice of
  /// which one last answered is dropped along with the value it referred to.
  String get baseUrl => endpoint.primary;
  set baseUrl(String value) {
    endpoint.primary = value;
    endpoint.reset();
  }

  String get backupUrl => endpoint.backup;
  set backupUrl(String value) {
    endpoint.backup = value;
    endpoint.reset();
  }

  /// Transcription of a short clip on a warm GPU is fast; a cold model load
  /// is not, and neither is a CPU-only server.
  static const Duration _timeout = Duration(seconds: 90);

  @override
  bool get isConfigured => endpoint.isConfigured;

  @override
  String? get configurationHint => isConfigured
      ? null
      : 'Set the server address, e.g. http://172.16.23.20:8000';

  /// True when the last transcription went through the remote address.
  bool get isOnBackup => endpoint.isOnBackup;

  /// Resolved transcription endpoint for a given candidate base.
  static Uri transcriptionUrl(String base) =>
      RemoteEndpoint.resolve(base, '/v1/audio/transcriptions');

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
      // Rebuilt per candidate: a MultipartRequest can only be sent once, and
      // the URL and headers differ between the LAN address and the tunnel.
      return await endpoint.withFailover((base) async {
        final request =
            http.MultipartRequest('POST', transcriptionUrl(base))
              ..headers.addAll(endpoint.headersFor(base, bearerToken: apiKey));
        request.fields['model'] =
            model.trim().isEmpty ? 'whisper-1' : model.trim();
        request.fields['response_format'] = 'json';
        if (languageCode != null && languageCode.isNotEmpty) {
          // The API wants a bare ISO-639-1 code, but Horizon stores recogniser
          // locales in `en_US` / `en-GB` form.
          request.fields['language'] =
              languageCode.split(RegExp('[-_]')).first;
        }
        request.files.add(await http.MultipartFile.fromPath('file', path));

        final streamed =
            await HorizonHttp.client.send(request).timeout(_timeout);
        final body = await streamed.stream.bytesToString();

        // Access redirects an unauthorised request to its login page and the
        // client follows it, so this arrives as a 200 full of HTML. Checked
        // before the status code for exactly that reason.
        final blocked = endpoint.describeAccessBlock(body, base);
        if (blocked != null) return SttResult.failure(blocked);

        if (streamed.statusCode != 200) {
          return SttResult.failure(
            'Whisper server: ${HttpErrorFormatter.formatHttpError(streamed.statusCode, body: body)}',
          );
        }

        final decoded = json.decode(body);
        final text = decoded is Map ? (decoded['text'] ?? '').toString() : '';
        return SttResult(text.trim());
      });
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
