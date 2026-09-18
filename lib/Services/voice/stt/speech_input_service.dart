import 'dart:async';
import 'dart:io';

import 'package:horizon/Services/voice/speech_recognition_service.dart';
import 'package:horizon/Services/voice/stt/elevenlabs_transcriber.dart';
import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Services/voice/stt/voice_recorder.dart';
import 'package:horizon/Services/voice/stt/whisper_transcriber.dart';

/// One speech-input interface over three backends.
///
/// The session controller talks only to this, so adding or switching a
/// backend never touches the state machine. [SttBackend.device] streams
/// partial words from the platform recogniser; the other two record a turn,
/// upload it, and return one final transcript.
///
/// A configured-but-unreachable remote backend falls back to the device
/// recogniser for that turn rather than failing, because losing what you just
/// said is worse than transcribing it less accurately. The fallback is
/// reported so the UI can say it happened.
class SpeechInputService {
  final SpeechRecognitionService device;
  final VoiceRecorder recorder;
  final WhisperTranscriber whisper;
  final ElevenLabsTranscriber elevenLabs;

  SpeechInputService({
    required this.device,
    required this.recorder,
    required this.whisper,
    required this.elevenLabs,
  });

  SttBackend backend = SttBackend.device;

  /// Recogniser locale, e.g. `en_US`. Empty means the device default, and for
  /// the remote backends it means auto-detect.
  String localeId = '';

  /// Set when the last turn silently used the device recogniser because the
  /// selected backend wasn't usable.
  String? lastFallbackReason;

  /// Live microphone level (0..1) while a remote backend records. The device
  /// recogniser shows words instead, so this stays idle for it.
  Stream<double> get levels => recorder.levels;

  /// The backend that will actually run, accounting for missing config.
  SttBackend get effectiveBackend {
    switch (backend) {
      case SttBackend.whisper:
        return whisper.isConfigured ? SttBackend.whisper : SttBackend.device;
      case SttBackend.elevenLabs:
        return elevenLabs.isConfigured
            ? SttBackend.elevenLabs
            : SttBackend.device;
      case SttBackend.device:
        return SttBackend.device;
    }
  }

  RecordedAudioTranscriber? _transcriberFor(SttBackend target) {
    switch (target) {
      case SttBackend.whisper:
        return whisper;
      case SttBackend.elevenLabs:
        return elevenLabs;
      case SttBackend.device:
        return null;
    }
  }

  bool get isListening => device.isListening || recorder.isRecording;

  /// Captures one turn and reports the transcript.
  ///
  /// [onResult] fires with partial text as it's recognised (device backend
  /// only) and once with `isFinal` when the turn is done. Returns false if
  /// listening couldn't start at all.
  Future<bool> listen({
    required void Function(String transcript, bool isFinal) onResult,
    void Function(String message)? onError,
  }) async {
    lastFallbackReason = null;
    final target = effectiveBackend;

    if (target != backend) {
      lastFallbackReason =
          '${backend.label} is not configured — used the device recogniser.';
    }

    if (target == SttBackend.device) {
      return device.listen(onResult: onResult, localeId: localeId);
    }

    return _listenRemote(target, onResult: onResult, onError: onError);
  }

  Future<bool> _listenRemote(
    SttBackend target, {
    required void Function(String transcript, bool isFinal) onResult,
    void Function(String message)? onError,
  }) async {
    if (!await recorder.hasPermission()) {
      onError?.call('Microphone permission is needed for voice mode.');
      return false;
    }

    // Deliberately not awaited: recordTurn() resolves when the speaker stops,
    // and listen() must return as soon as the microphone is live so the UI can
    // show it.
    unawaited(_runRemoteTurn(target, onResult, onError));
    return true;
  }

  Future<void> _runRemoteTurn(
    SttBackend target,
    void Function(String transcript, bool isFinal) onResult,
    void Function(String message)? onError,
  ) async {
    String? recordedPath;
    try {
      recordedPath = await recorder.recordTurn();
      if (recordedPath == null) {
        // Nothing said, or cancelled. An empty final result returns the
        // session to idle without an error message.
        onResult('', true);
        return;
      }

      final transcriber = _transcriberFor(target);
      if (transcriber == null) {
        onResult('', true);
        return;
      }

      final result = await transcriber.transcribe(
        recordedPath,
        languageCode: localeId,
      );

      if (result.error != null) {
        // Report it, then hand back an empty final so the turn ends cleanly
        // instead of the UI waiting on a transcript that isn't coming.
        onError?.call(result.error!);
        onResult('', true);
        return;
      }

      onResult(result.text, true);
    } catch (e) {
      onError?.call('Recording failed: $e');
      onResult('', true);
    } finally {
      await _deleteRecording(recordedPath);
    }
  }

  /// Ends the turn, keeping what was captured.
  Future<void> stop() async {
    recorder.finish();
    await device.stop();
  }

  /// Ends the turn and discards it.
  Future<void> cancel() async {
    recorder.cancel();
    await device.cancel();
  }

  Future<void> dispose() async {
    await recorder.dispose();
  }

  /// Turn audio is deleted the moment it has been transcribed. It's a
  /// recording of the user's voice; keeping it around buys nothing.
  Future<void> _deleteRecording(String? path) async {
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Locales the device recogniser supports, for the settings picker. The
  /// remote backends accept any language code, so the same list is offered.
  Future<List<({String id, String name})>> locales() => device.locales();
}
