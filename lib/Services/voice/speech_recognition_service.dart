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

  /// How long to keep listening with no speech before giving up.
  static const Duration _listenTimeout = Duration(seconds: 30);

  /// How much trailing silence ends the turn. Short enough to feel responsive,
  /// long enough to survive someone pausing to think mid-sentence.
  static const Duration _pauseTimeout = Duration(seconds: 3);

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
    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult result) {
          onResult(result.recognizedWords, result.finalResult);
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
    try {
      if (_speech.isListening) await _speech.stop();
    } catch (_) {}
  }

  /// Ends the turn and discards what was heard.
  Future<void> cancel() async {
    try {
      if (_speech.isListening) await _speech.cancel();
    } catch (_) {}
  }

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
