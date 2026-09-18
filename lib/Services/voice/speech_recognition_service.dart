import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Wraps on-device speech recognition.
///
/// Uses the platform recogniser, which is free, needs no key, and on Android
/// can run offline once a language pack is downloaded. The interface is
/// deliberately narrow — start, stop, a stream of transcripts — so a
/// server-side Whisper backend can be dropped in behind it later without the
/// voice session knowing.
class SpeechRecognitionService {
  final SpeechToText _speech = SpeechToText();

  bool _initialized = false;
  bool _available = false;

  /// Whether the platform has a usable recogniser and permission was granted.
  bool get isAvailable => _available;

  bool get isListening => _speech.isListening;

  /// Last initialisation/recognition error, for showing the user something
  /// better than a mic button that does nothing.
  String? lastError;

  /// Hard ceiling on one turn. Only reached if our own endpointing and the
  /// platform's both fail; the real end-of-turn detection is [_silenceWindow].
  static const Duration _listenTimeout = Duration(seconds: 45);

  /// What we ask the platform for. Android's SpeechRecognizer treats this as
  /// a hint and frequently ignores it outright, which is why it can't be
  /// relied on — see [_silenceWindow].
  static const Duration _pauseTimeout = Duration(seconds: 2);

  /// How long the transcript must stop changing before we call the turn over.
  ///
  /// This is the endpointing that actually works. Android's `pauseFor` is
  /// widely ignored, so a turn would run to `listenFor` — 30 seconds of dead
  /// air after you stopped talking. Watching the partial results go quiet is
  /// independent of the platform honouring anything.
  static const Duration _silenceWindow = Duration(milliseconds: 1100);

  Timer? _silenceTimer;
  String _lastTranscript = '';

  /// Prepares the recogniser and asks for microphone permission. Safe to call
  /// repeatedly; the underlying plugin only initialises once.
  Future<bool> initialize() async {
    if (_initialized) return _available;
    try {
      _available = await _speech.initialize(
        onError: _handleError,
        // Deliberately not handling onStatus here: the session controller owns
        // the state machine and infers "done" from the final result callback.
        debugLogging: false,
      );
      if (!_available) {
        lastError ??= 'This device has no speech recogniser available.';
      }
    } catch (e) {
      _available = false;
      lastError = 'Speech recognition is unavailable: $e';
    }
    _initialized = true;
    return _available;
  }

  void _handleError(SpeechRecognitionError error) {
    // `error_no_match` and `error_speech_timeout` mean "heard nothing", which
    // is a normal outcome of tapping the mic and not speaking — not a fault
    // worth showing.
    if (error.errorMsg == 'error_no_match' ||
        error.errorMsg == 'error_speech_timeout') {
      return;
    }
    lastError = _describe(error.errorMsg);
  }

  static String _describe(String code) {
    switch (code) {
      case 'error_permission':
      case 'error_insufficient_permissions':
        return 'Microphone permission is needed for voice mode.';
      case 'error_network':
      case 'error_network_timeout':
        return 'The speech recogniser could not reach the network. Download an '
            'offline language pack, or check the connection.';
      case 'error_busy':
        return 'The microphone is busy — another app may be using it.';
      case 'error_language_not_supported':
        return 'The selected language is not supported by this device.';
      default:
        return 'Speech recognition failed ($code).';
    }
  }

  /// Starts listening. [onResult] fires for partial results as the user speaks
  /// and once more with `isFinal` set when the turn ends.
  Future<bool> listen({
    required void Function(String transcript, bool isFinal) onResult,
    String? localeId,
  }) async {
    if (!await initialize()) return false;
    if (_speech.isListening) return true;

    lastError = null;
    _lastTranscript = '';
    _silenceTimer?.cancel();

    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          final words = result.recognizedWords;

          // Restart the silence countdown whenever the transcript grows.
          if (words != _lastTranscript) {
            _lastTranscript = words;
            _silenceTimer?.cancel();
            if (words.trim().isNotEmpty) {
              _silenceTimer = Timer(_silenceWindow, () {
                // stop() finalises the turn, which delivers a result with
                // isFinal set through this same callback.
                unawaited(stop());
              });
            }
          }

          if (result.finalResult) _silenceTimer?.cancel();
          onResult(words, result.finalResult);
        },
        listenOptions: SpeechListenOptions(
          // Dictation-style: keep going through short pauses and give us
          // partials so the UI can show words as they land.
          listenMode: ListenMode.dictation,
          partialResults: true,
          cancelOnError: true,
          // Not forced on-device: where a device can't do it locally, forcing
          // it fails the listen outright rather than degrading.
          onDevice: false,
          localeId: (localeId == null || localeId.isEmpty) ? null : localeId,
          listenFor: _listenTimeout,
          pauseFor: _pauseTimeout,
        ),
      );
      return true;
    } catch (e) {
      lastError = 'Could not start listening: $e';
      return false;
    }
  }

  /// Ends the turn and keeps whatever was heard.
  Future<void> stop() async {
    _silenceTimer?.cancel();
    try {
      if (_speech.isListening) await _speech.stop();
    } catch (_) {}
  }

  /// Ends the turn and discards what was heard.
  Future<void> cancel() async {
    _silenceTimer?.cancel();
    try {
      if (_speech.isListening) await _speech.cancel();
    } catch (_) {}
  }

  /// Gets the platform recogniser ready before it's needed.
  ///
  /// First-time [initialize] involves a platform round-trip and a permission
  /// check; doing it when the voice screen opens rather than on the first tap
  /// is the difference between the mic being live immediately and a visible
  /// delay.
  Future<void> prewarm() => initialize();

  /// Locales the device can recognise.
  Future<List<({String id, String name})>> locales() async {
    if (!await initialize()) return const [];
    try {
      final locales = await _speech.locales();
      return locales
          .map((l) => (id: l.localeId, name: l.name))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } catch (_) {
      return const [];
    }
  }
}
