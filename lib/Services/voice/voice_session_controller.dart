import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Services/voice/stt/speech_input_service.dart';

enum VoicePhase {
  /// Nothing happening; tap to talk.
  idle,

  /// Microphone open, transcribing.
  listening,

  /// Prompt sent, waiting on (or receiving) the model's reply.
  thinking,

  /// Reading the reply aloud.
  speaking,

  /// Something went wrong; [VoiceSessionController.error] says what.
  error,
}

/// Drives a hands-free turn: listen, send, speak.
///
/// Deliberately a thin layer over [ChatProvider] rather than a parallel chat
/// implementation. Voice mode talks to a normal chat — the "assistant chat" —
/// so the same provider routing, tools, system prompt and history apply, and
/// anything said by voice is there in the chat list afterwards to read back.
class VoiceSessionController extends ChangeNotifier {
  final ChatProvider _chatProvider;
  final SpeechInputService _recognition;
  final SpeechSynthesisService _synthesis;

  VoiceSessionController({
    required ChatProvider chatProvider,
    required SpeechInputService recognition,
    required SpeechSynthesisService synthesis,
  })  : _chatProvider = chatProvider,
        _recognition = recognition,
        _synthesis = synthesis {
    _chatProvider.addListener(_onChatChanged);
    _chatProvider.streamingContent.addListener(_onStreamingText);
  }

  VoicePhase _phase = VoicePhase.idle;
  VoicePhase get phase => _phase;

  String? error;

  /// What the user is saying / just said.
  String transcript = '';

  /// The reply text as it arrives, for the on-screen caption.
  String reply = '';

  /// Whether replies get read aloud at all. Off makes this a dictation box.
  bool speakReplies = true;

  /// How much of [reply] has already been handed to the synthesiser.
  int _spokenUpTo = 0;

  /// True between sending a prompt and the stream finishing, so a stray
  /// notification from an unrelated chat can't end the turn.
  bool _awaitingReply = false;

  bool get isBusy =>
      _phase == VoicePhase.listening ||
      _phase == VoicePhase.thinking ||
      _phase == VoicePhase.speaking;

  /// What the assistant is doing out-of-band, e.g. "Reading example.com…".
  String? get activity => _chatProvider.currentChatActivity;

  /// Live microphone level, 0..1, while a recording backend is capturing.
  /// Whisper and Scribe transcribe a finished clip, so there are no partial
  /// words to show and this is the only sign the microphone is working.
  Stream<double> get levels => _recognition.levels;

  /// True when the active backend shows a level meter rather than live text.
  bool get showsLevelMeter =>
      !_recognition.effectiveBackend.hasPartialResults;

  /// Set when the chosen backend wasn't usable and the device recogniser was
  /// used for the last turn instead.
  String? get fallbackNotice => _recognition.lastFallbackReason;

  @override
  void dispose() {
    _chatProvider.removeListener(_onChatChanged);
    _chatProvider.streamingContent.removeListener(_onStreamingText);
    _recognition.cancel();
    _synthesis.stop();
    super.dispose();
  }

  void _setPhase(VoicePhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    notifyListeners();
  }

  /// The single button: start listening, or interrupt whatever is happening.
  ///
  /// Interruption is the point — being unable to cut off a wrong answer is
  /// what makes a voice assistant feel broken.
  Future<void> toggle() async {
    switch (_phase) {
      case VoicePhase.listening:
        await _recognition.stop();
      case VoicePhase.thinking:
      case VoicePhase.speaking:
        await interrupt();
      case VoicePhase.idle:
      case VoicePhase.error:
        await startListening();
    }
  }

  /// Stops generation and speech, and goes straight back to listening so the
  /// user can immediately rephrase.
  Future<void> interrupt() async {
    _awaitingReply = false;
    await _synthesis.stop();
    _chatProvider.cancelCurrentStreaming();
    _setPhase(VoicePhase.idle);
    await startListening();
  }

  Future<void> startListening() async {
    // Never record while the device is talking, or the recogniser transcribes
    // the assistant's own voice back into the next prompt.
    await _synthesis.stop();

    error = null;
    transcript = '';
    reply = '';
    _spokenUpTo = 0;
    _setPhase(VoicePhase.listening);

    final started = await _recognition.listen(
      onResult: _onRecognitionResult,
      onError: (message) {
        error = message;
        notifyListeners();
      },
    );

    if (!started) {
      error ??= 'Could not start listening. Check microphone permission.';
      _setPhase(VoicePhase.error);
    }
  }

  void _onRecognitionResult(String text, bool isFinal) {
    transcript = text;
    notifyListeners();
    if (!isFinal) return;

    final prompt = text.trim();
    if (prompt.isEmpty) {
      // A remote backend reports a transcription failure by setting `error`
      // and then handing back an empty final, so the two cases are told
      // apart here: something broke, versus nobody said anything.
      _setPhase(error == null ? VoicePhase.idle : VoicePhase.error);
      return;
    }
    unawaited(_send(prompt));
  }

  /// Sends a typed prompt through the same path as a spoken one, so the reply
  /// still streams and is still read aloud. For the times when dictation
  /// keeps mishearing a word, or you're somewhere you can't talk.
  Future<void> sendText(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || isBusy) return;

    // Stop any residual playback first, or the previous answer talks over the
    // new one's opening sentence.
    await _synthesis.stop();
    await _recognition.cancel();

    error = null;
    transcript = prompt;
    notifyListeners();
    await _send(prompt);
  }

  Future<void> _send(String prompt) async {
    _setPhase(VoicePhase.thinking);
    reply = '';
    _spokenUpTo = 0;
    _awaitingReply = true;

    try {
      await _chatProvider.sendPrompt(prompt);
    } catch (e) {
      _awaitingReply = false;
      error = 'Could not send that: $e';
      _setPhase(VoicePhase.error);
      return;
    }

    // sendPrompt resolves when the whole turn is done, tools included. The
    // streaming listener has been feeding the synthesiser throughout; flush
    // whatever is left of the final sentence.
    if (!_awaitingReply) return; // interrupted
    _awaitingReply = false;

    final chatError = _chatProvider.currentChatError;
    if (chatError != null) {
      error = chatError.message;
      if (speakReplies) {
        await _synthesis.speakNow('Something went wrong. $error');
      }
      _setPhase(VoicePhase.error);
      return;
    }

    _flushRemainingSpeech();
    _setPhase(_synthesis.isSpeaking ? VoicePhase.speaking : VoicePhase.idle);
    await _waitForSpeechToFinish();
  }

  Future<void> _waitForSpeechToFinish() async {
    while (_synthesis.isSpeaking && _phase == VoicePhase.speaking) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
    if (_phase == VoicePhase.speaking) _setPhase(VoicePhase.idle);
  }

  void _onChatChanged() {
    // Surfaces tool activity ("Searching for …") while thinking.
    if (_phase == VoicePhase.thinking) notifyListeners();
  }

  /// Feeds completed sentences to the synthesiser as the reply streams in, so
  /// speech starts a second or two into generation instead of after it.
  void _onStreamingText() {
    if (!_awaitingReply) return;

    reply = _chatProvider.streamingContent.value;
    notifyListeners();

    if (!speakReplies) return;

    final boundary = sentenceBoundary(reply, from: _spokenUpTo);
    if (boundary <= _spokenUpTo) return;

    final chunk = reply.substring(_spokenUpTo, boundary);
    _spokenUpTo = boundary;
    _synthesis.enqueue(chunk);
    if (_phase == VoicePhase.thinking) _setPhase(VoicePhase.speaking);
  }

  void _flushRemainingSpeech() {
    if (!speakReplies) return;
    if (_spokenUpTo >= reply.length) return;
    final tail = reply.substring(_spokenUpTo);
    _spokenUpTo = reply.length;
    _synthesis.enqueue(tail);
  }

  /// Index just past the *last* sentence terminator at or after [from], or
  /// [from] if there isn't a long enough complete sentence yet.
  ///
  /// The last rather than the first: when several sentences land in one
  /// streaming tick they're better spoken as a single utterance — the engine
  /// gets the prosody right across the boundary, and on ElevenLabs it's one
  /// request instead of three.
  ///
  /// The minimum length stops the synthesiser being handed "1." or "Dr." as
  /// its own clip, which sounds like a stutter and costs an ElevenLabs request
  /// per fragment.
  static int sentenceBoundary(String text, {required int from}) {
    const minimumChunk = 24;
    if (text.length - from < minimumChunk) return from;

    var boundary = from;
    for (var i = from; i < text.length; i++) {
      final char = text[i];
      if (char == '\n') {
        // A line break is itself the separator — nothing needs to follow it.
        if (i + 1 - from >= minimumChunk) boundary = i + 1;
        continue;
      }
      if (char == '.' || char == '!' || char == '?') {
        // Punctuation only terminates a sentence when whitespace or the end
        // of the text follows, so "version 2.3" and "Dr." stay intact.
        final next = i + 1 < text.length ? text[i + 1] : ' ';
        if (next == ' ' || next == '\n' || next == '\t') {
          if (i + 1 - from >= minimumChunk) boundary = i + 1;
        }
      }
    }
    return boundary;
  }
}
