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

  /// Recogniser locale, e.g. `en_US`. Empty means this device's language;
  /// [autoDetectLocale] means let the server work it out per recording.
  String localeId = '';

  /// Sentinel for "no language, let the server detect it".
  ///
  /// Deliberately a separate choice from the empty default rather than the
  /// meaning of it: detection is the option that *sounds* safest and isn't,
  /// so it shouldn't be what you get by not choosing.
  static const String autoDetectLocale = 'auto';

  /// Language code handed to the recording backends.
  ///
  /// Empty used to mean "let the server auto-detect", which is a bad trade on
  /// a single short clip recorded somewhere noisy: detection runs on the
  /// first window of audio, and when it guesses wrong the result isn't an
  /// error, it's fluent nonsense in another language. The device's own
  /// language is a far better prior — and it's what "device default" in the
  /// picker says it is.
  String get resolvedLanguage {
    if (localeId == autoDetectLocale) return '';
    final locale = localeId.isNotEmpty ? localeId : _platformLocale();
    // Must be a bare ISO-639-1 code or nothing. A Linux session with LANG=C
    // reports "C", and `language=c` is not a graceful no-op — Speaches
    // answers **HTTP 500** and the turn is lost.
    final code = locale.split(RegExp('[-_.]')).first.toLowerCase();
    return RegExp(r'^[a-z]{2}$').hasMatch(code) ? code : '';
  }

  static String _platformLocale() {
    try {
      return Platform.localeName; // en_US, or en_US.UTF-8 on Linux
    } catch (_) {
      return '';
    }
  }

  /// Text Whisper invents when handed a clip with no speech in it, one or two
  /// words long. Its longer stock phrases ("thanks for watching and see you
  /// next time") are already impossible inside half a second and are caught
  /// by the word count instead.
  ///
  /// "thanks" and "bye" were on this list and have been taken off: they are
  /// ordinary ways to end a turn, and dropping a real one is worse than
  /// passing on a phantom.
  static const Set<String> _phantomTranscripts = {
    'thank you',
    'you',
    'blank audio',
    'silence',
    'music',
  };

  /// Set when the last turn silently used the device recogniser because the
  /// selected backend wasn't usable.
  String? lastFallbackReason;

  /// Something worth saying about the last turn even though it worked.
  ///
  /// One case: the room is loud enough that hearing the end of a sentence is
  /// unreliable, so turns get cut short. Without saying so, that reads as
  /// being interrupted for no reason — when the answer is simply to end turns
  /// by hand while you're somewhere this loud.
  String? lastTurnNotice;

  /// Room level, in dBFS, above which ambience is close enough to a speaking
  /// voice that the end of a sentence can't be heard reliably.
  static const double _loudRoomDb = -22.0;

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
    lastTurnNotice = null;
    final target = effectiveBackend;

    if (target != backend) {
      lastFallbackReason =
          '${backend.label} is not configured — used the device recogniser.';
    }

    if (target == SttBackend.device) {
      // The platform recogniser has no notion of "detect it": handing it the
      // sentinel as a locale id would be handing it an invalid one.
      return device.listen(
        onResult: onResult,
        localeId: localeId == autoDetectLocale ? '' : localeId,
      );
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
      final room = recorder.lastTurnRoomDb;
      lastTurnNotice =
          recorder.lastTurnEndedOnNoise || (room != null && room > _loudRoomDb)
              ? "It's loud here, so the end of a turn is hard to hear. Tap "
                  'when you have finished speaking.'
              : null;
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
        languageCode: resolvedLanguage,
      );

      if (result.error != null) {
        // A server that rejected the upload may simply not decode compressed
        // audio — whisper.cpp's bundled server is WAV-only. Rather than
        // failing every turn from here on with an HTTP error and no clue,
        // fall back for the rest of the session and say so. One turn is lost
        // either way; this way only one is.
        // Statuses that can mean "I couldn't read that audio". An auth
        // failure or a missing model is also a rejection and has nothing to
        // do with the format, so it must not flip anything.
        final unreadable = result.serverRejected &&
            const {400, 415, 422, 500}.contains(result.statusCode);
        final message = unreadable && !recorder.uploadUncompressed
            ? '${result.error!} Switching to uncompressed audio for now — '
                'Settings → Voice can make that permanent.'
            : result.error!;
        // A timeout or an unreachable server says nothing about the audio
        // format, and switching on one would trade the ten-fold smaller
        // upload away for no reason.
        if (unreadable) recorder.uploadUncompressed = true;

        // Report it, then hand back an empty final so the turn ends cleanly
        // instead of the UI waiting on a transcript that isn't coming.
        onError?.call(message);
        onResult('', true);
        return;
      }

      if (isPhantomTranscript(result.text, recorder.lastTurnSpeechDuration)) {
        // Treat it as silence: the continuous loop then listens again instead
        // of sending the room's words to the model as if they were yours.
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

  /// Whether a transcript is something the recogniser invented rather than
  /// something that was said, judged against how much speech the recorder
  /// actually heard.
  ///
  /// Two independent checks, both physical rather than a phrase blacklist
  /// where it can be avoided:
  ///  - more than two words out of under half a second of speech is not
  ///    something a human said;
  ///  - the handful of stock phrases Whisper emits for pure noise, and only
  ///    when the turn was nearly silent. Short genuine answers — "yeah",
  ///    "no", "stop" — are deliberately NOT on that list.
  static bool isPhantomTranscript(String text, Duration? speech) {
    final words = text
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9' ]"), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return true;

    // Null means the recorder kept the turn without ever resolving speech in
    // it: a manual stop somewhere too loud for the level meter. The word
    // count says nothing then — there is no duration to compare it against,
    // and a real sentence is exactly what that path exists to rescue — but
    // the stock phrases still hold, because they are what a clip of pure
    // room comes back as.
    if (speech == null) return _phantomTranscripts.contains(words.join(' '));

    if (speech >= _judgeSpeechUnder) return false;
    // More words than a mouth can produce in the time speech was heard.
    // Three in under half a second is not something a person said.
    if (speech < _impossibleWordsUnder && words.length >= 3) return true;
    return words.length <= 2 &&
        _phantomTranscripts.contains(words.join(' '));
  }

  /// Above this much detected speech a transcript is taken at face value.
  static const Duration _judgeSpeechUnder = Duration(milliseconds: 600);

  /// Below this much detected speech, three or more words are impossible.
  static const Duration _impossibleWordsUnder = Duration(milliseconds: 500);

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
