import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/voice/speech_recognition_service.dart';
import 'package:horizon/Services/voice/stt/elevenlabs_transcriber.dart';
import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Services/voice/stt/speech_input_service.dart';
import 'package:horizon/Services/voice/stt/voice_recorder.dart';
import 'package:horizon/Services/voice/stt/whisper_transcriber.dart';

SpeechInputService buildService({
  String? whisperUrl,
  String? elevenLabsKey,
}) {
  return SpeechInputService(
    device: SpeechRecognitionService(),
    recorder: VoiceRecorder(),
    whisper: WhisperTranscriber(baseUrl: whisperUrl),
    elevenLabs: ElevenLabsTranscriber(apiKey: elevenLabsKey),
  );
}

void main() {
  group('SttBackend', () {
    test('round-trips through its stored value', () {
      for (final backend in SttBackend.values) {
        expect(SttBackend.fromString(backend.storageValue), backend);
      }
    });

    test('an unknown or absent value falls back to the device recogniser', () {
      expect(SttBackend.fromString(null), SttBackend.device);
      expect(SttBackend.fromString('deepgram'), SttBackend.device);
    });

    test('only the device backend has partial results', () {
      expect(SttBackend.device.hasPartialResults, isTrue);
      expect(SttBackend.whisper.hasPartialResults, isFalse);
      expect(SttBackend.elevenLabs.hasPartialResults, isFalse);
    });

    test('the remote backends are the ones that need recording', () {
      expect(SttBackend.device.needsRecording, isFalse);
      expect(SttBackend.whisper.needsRecording, isTrue);
      expect(SttBackend.elevenLabs.needsRecording, isTrue);
    });
  });

  group('backend fallback', () {
    test('an unconfigured Whisper server falls back to the device', () {
      final service = buildService()..backend = SttBackend.whisper;
      // Losing what you just said is worse than transcribing it less well.
      expect(service.effectiveBackend, SttBackend.device);
    });

    test('a configured Whisper server is used', () {
      final service = buildService(whisperUrl: 'http://172.16.23.20:8000')
        ..backend = SttBackend.whisper;
      expect(service.effectiveBackend, SttBackend.whisper);
    });

    test('Scribe without a key falls back to the device', () {
      final service = buildService()..backend = SttBackend.elevenLabs;
      expect(service.effectiveBackend, SttBackend.device);
    });

    test('Scribe with a key is used', () {
      final service = buildService(elevenLabsKey: 'sk_test')
        ..backend = SttBackend.elevenLabs;
      expect(service.effectiveBackend, SttBackend.elevenLabs);
    });

    test('the device backend never falls back to anything', () {
      final service = buildService(
        whisperUrl: 'http://x.test',
        elevenLabsKey: 'sk_test',
      )..backend = SttBackend.device;
      expect(service.effectiveBackend, SttBackend.device);
    });
  });

  group('WhisperTranscriber endpoint', () {
    test('appends the API path to a bare host and port', () {
      final w = WhisperTranscriber(baseUrl: 'http://172.16.23.20:8000');
      expect(WhisperTranscriber.transcriptionUrl(w.baseUrl).toString(),
          'http://172.16.23.20:8000/v1/audio/transcriptions');
    });

    test('assumes http when no scheme is given', () {
      final w = WhisperTranscriber(baseUrl: '172.16.23.20:8000');
      expect(WhisperTranscriber.transcriptionUrl(w.baseUrl).scheme, 'http');
      expect(WhisperTranscriber.transcriptionUrl(w.baseUrl).host, '172.16.23.20');
    });

    test('tolerates a trailing slash', () {
      final w = WhisperTranscriber(baseUrl: 'http://whisper.test/');
      expect(
          WhisperTranscriber.transcriptionUrl(w.baseUrl).toString(), 'http://whisper.test/v1/audio/transcriptions');
    });

    test('does not double up when the base already includes /v1', () {
      // These servers are usually documented with the /v1 included, so pasting
      // it verbatim must not produce /v1/v1/audio/transcriptions.
      final w = WhisperTranscriber(baseUrl: 'https://api.openai.com/v1');
      expect(WhisperTranscriber.transcriptionUrl(w.baseUrl).toString(),
          'https://api.openai.com/v1/audio/transcriptions');
    });

    test('keeps https when given', () {
      final w = WhisperTranscriber(baseUrl: 'https://api.groq.com/openai/v1');
      expect(WhisperTranscriber.transcriptionUrl(w.baseUrl).toString(),
          'https://api.groq.com/openai/v1/audio/transcriptions');
    });
  });

  group('configuration reporting', () {
    test('Whisper needs a base URL and says so', () {
      final w = WhisperTranscriber();
      expect(w.isConfigured, isFalse);
      expect(w.configurationHint, contains('server address'));

      w.baseUrl = 'http://whisper.test';
      expect(w.isConfigured, isTrue);
      expect(w.configurationHint, isNull);
    });

    test('whitespace is not configuration', () {
      expect(WhisperTranscriber(baseUrl: '   ').isConfigured, isFalse);
      expect(ElevenLabsTranscriber(apiKey: '  ').isConfigured, isFalse);
    });

    test('Scribe needs a key and says so', () {
      final s = ElevenLabsTranscriber();
      expect(s.isConfigured, isFalse);
      expect(s.configurationHint, contains('key'));

      s.apiKey = 'sk_test';
      expect(s.isConfigured, isTrue);
      expect(s.configurationHint, isNull);
    });
  });

  group('transcription failures are data, not exceptions', () {
    test('an unconfigured Whisper server reports rather than throws', () async {
      final result = await WhisperTranscriber().transcribe('/tmp/none.wav');
      expect(result.error, isNotNull);
      expect(result.isEmpty, isTrue);
    });

    test('an unconfigured Scribe reports rather than throws', () async {
      final result = await ElevenLabsTranscriber().transcribe('/tmp/none.wav');
      expect(result.error, isNotNull);
    });

    test('a missing recording is reported, not thrown', () async {
      final result = await WhisperTranscriber(baseUrl: 'http://whisper.test')
          .transcribe('/tmp/definitely-not-here-${DateTime.now()}.wav');
      expect(result.error, contains('disappeared'));
    });
  });

  group('SttResult', () {
    test('a successful result carries no error', () {
      const result = SttResult('hello there');
      expect(result.error, isNull);
      expect(result.isEmpty, isFalse);
    });

    test('whitespace-only text counts as empty', () {
      expect(const SttResult('   ').isEmpty, isTrue);
    });
  });
}
