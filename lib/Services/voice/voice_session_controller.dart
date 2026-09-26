import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:horizon/Providers/chat_provider.dart';
import 'package:horizon/Services/voice/speech_synthesis_service.dart';
import 'package:horizon/Services/voice/stt/speech_input_service.dart';
import 'package:horizon/Services/voice/stt/whisper_live_client.dart';

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
    _synthesis.startedChunks.addListener(notifyListeners);
    // The live backend reports more than a string: which words it has
    // finalised, and which are still being revised. Plain text still arrives
    // through the ordinary result callback, so this only feeds the display.
    _levelUpdates = _recognition.levels.listen((_) {
      if (_phase != VoicePhase.listening || hearing) return;
      hearing = true;
      _heardOnce = true;
      notifyListeners();
    });
    _liveUpdates = _recognition.liveTranscripts.listen((live) {
      if (_phase != VoicePhase.listening) return;
      liveCommitted = live.committed;
      liveTail = live.tail;
      notifyListeners();
    });
  }

  StreamSubscription<LiveTranscript>? _liveUpdates;
  StreamSubscription<double>? _levelUpdates;

  /// Whether audio is actually arriving this turn. "Listening" is only true
  /// once it is: the screen used to say it the moment the microphone was
  /// asked for, a second before it delivered anything, and people started
  /// talking into that second.
  bool hearing = false;

  VoicePhase _phase = VoicePhase.idle;
  VoicePhase get phase => _phase;

  String? error;

  /// What the user is saying / just said.
  String transcript = '';

  /// The finalised part of what is being said right now, and the part still
  /// being revised. Only the live backend fills these in; everything else
  /// leaves [liveTail] empty and puts the whole thing in [transcript].
  ///
  /// Worth the extra two fields: showing the revisable tail dimmed is the
  /// difference between live transcription looking alive and looking broken,
  /// because the tail *does* visibly change its mind mid-sentence.
  String liveCommitted = '';
  String liveTail = '';

  /// Let the user cut the assistant off by talking over it, rather than
  /// having to tap. Off by default — see
  /// [StreamingSpeechSession.watchForOnset]: through a loudspeaker with weak
  /// echo cancellation, the assistant's own voice can trip it.
  bool interruptByTalking = false;

  /// The reply text as it arrives, for the on-screen caption.
  String reply = '';

  /// Everything said earlier in this session, oldest first, so the screen
  /// reads as a conversation rather than wiping itself every turn. Only for
  /// the screen: the chat itself keeps the whole history regardless, and a
  /// new session — a new controller — starts with this empty.
  final List<({bool fromUser, String text})> history = [];

  /// Moves the finished exchange into [history] before a new one starts.
  void _archiveTurn() {
    final said = transcript.trim();
    final answered = reply.trim();
    if (said.isNotEmpty) history.add((fromUser: true, text: said));
    if (answered.isNotEmpty && error == null) history.add((fromUser: false, text: answered));
  }

  /// Whether replies get read aloud at all. Off makes this a dictation box.
  bool speakReplies = true;

  /// Keep the conversation going: after a reply finishes, listen again
  /// without waiting for a tap. This is what makes it a conversation rather
  /// than a series of one-shot queries, and it's the default because tapping
  /// between every turn is the main thing that makes voice feel like work.
  ///
  /// The mic is only open during a listening phase — never while thinking or
  /// speaking — so it isn't always-on recording.
  bool continuousMode = true;

  /// Set when the loop stopped because nothing was said, so the UI can show
  /// "still there?" rather than silently going idle.
  bool endedOnSilence = false;

  /// Consecutive turns that heard nothing. The loop stops eventually so a
  /// forgotten session doesn't sit with the mic open indefinitely — but not
  /// after two: at eight seconds a turn that was sixteen seconds of patience,
  /// and pausing to think then meant tapping the mic again.
  int _silentTurns = 0;
  static const int _maxSilentTurns = 5;

  /// How much of [reply] has already been handed to the synthesiser.
  int _spokenUpTo = 0;

  /// Where each chunk handed to the synthesiser ends in [reply], in order,
  /// and the synthesiser's chunk count when this reply began. Together they
  /// say which stretch of the reply is coming out of the speaker right now.
  final List<int> _chunkEnds = [];
  int _chunkBase = 0;

  /// The part of [reply] being spoken right now, as `(start, end)`, or null
  /// when nothing of this reply is playing yet. What the caption lights up.
  (int, int)? get speakingRange {
    final index = _synthesis.startedChunks.value - _chunkBase - 1;
    if (index < 0 || index >= _chunkEnds.length) return null;
    final start = index == 0 ? 0 : _chunkEnds[index - 1];
    return (start, _chunkEnds[index].clamp(start, reply.length));
  }

  void _resetChunks() {
    _chunkEnds.clear();
    _chunkBase = _synthesis.startedChunks.value;
  }

  /// True between sending a prompt and the stream finishing, so a stray
  /// notification from an unrelated chat can't end the turn.
  bool _awaitingReply = false;

  /// Set once the held microphone has delivered audio in this session —
  /// from then on a new turn is hearing from its first moment.
  bool get _heardBefore => _heardOnce;
  bool _heardOnce = false;

  bool get isBusy =>
      _phase == VoicePhase.listening ||
      _phase == VoicePhase.thinking ||
      _phase == VoicePhase.speaking;

  /// What the assistant is doing out-of-band, e.g. "Reading example.com…".
  String? get activity => _chatProvider.currentChatActivity;

  /// Live microphone level, 0..1, whenever this app is doing the capturing.
  ///
  /// Shown for the live backend *as well as* the upload ones: with words on
  /// screen it is no longer the only feedback, but it is still the only thing
  /// that distinguishes "listening, you haven't said anything" from
  /// "listening, and a word is on its way".
  Stream<double> get levels => _recognition.levels;

  /// Null for the platform recogniser, which has no meter of its own.
  Stream<double>? get orbLevels =>
      _recognition.effectiveBackend.needsRecording ? _recognition.levels : null;

  /// True when the active backend can only show a level meter, because it
  /// transcribes a finished clip and has no words until the turn is over.
  bool get showsLevelMeter =>
      !_recognition.effectiveBackend.hasPartialResults;

  /// Anything the last turn needs to say for itself: that the chosen backend
  /// wasn't usable and the device recogniser covered for it, or that the turn
  /// was ended by the endpointer because the room never went quiet.
  String? get fallbackNotice =>
      _recognition.lastFallbackReason ?? _recognition.lastTurnNotice;

  @override
  void dispose() {
    unawaited(_liveUpdates?.cancel());
    unawaited(_levelUpdates?.cancel());
    unawaited(_recognition.releaseMicrophone());
    unawaited(_recognition.stopWatching());
    _chatProvider.removeListener(_onChatChanged);
    _chatProvider.streamingContent.removeListener(_onStreamingText);
    _synthesis.startedChunks.removeListener(notifyListeners);
    _recognition.cancel();
    _synthesis.stop();
    super.dispose();
  }

  void _setPhase(VoicePhase phase) {
    if (_phase == phase) return;
    final wasSpeaking = _phase == VoicePhase.speaking;
    _phase = phase;
    _recognition.assistantSpeaking = phase == VoicePhase.speaking;
    notifyListeners();

    // Arm and disarm the interruption watcher on the edges of the speaking
    // phase, rather than at each of the several places that start speech.
    if (phase == VoicePhase.speaking) {
      unawaited(_armInterruption());
    } else if (wasSpeaking) {
      unawaited(_recognition.stopWatching());
    }
  }

  /// Opens the microphone to listen only for the user starting to talk while
  /// the assistant is reading a reply out.
  Future<void> _armInterruption() async {
    if (!interruptByTalking || !_recognition.canWatchForOnset) return;
    await _recognition.watchForOnset(onSpeech: () {
      // Phases move on their own; by the time speech is heard the reply may
      // already have finished, and interrupting nothing would restart the
      // microphone behind the user's back.
      if (_phase != VoicePhase.speaking) return;
      unawaited(interrupt());
    });
  }

  /// The single button: start listening, or interrupt whatever is happening.
  ///
  /// Interruption is the point — being unable to cut off a wrong answer is
  /// what makes a voice assistant feel broken.
  Future<void> toggle() async {
    switch (_phase) {
      case VoicePhase.listening:
        // Tapping while it listens means "I'm done" — finalise this turn and
        // leave the loop, rather than dropping straight back into listening.
        _leaving = true;
        await _recognition.stop();
      case VoicePhase.thinking:
      case VoicePhase.speaking:
        await interrupt();
      case VoicePhase.idle:
      case VoicePhase.error:
        // A tap is the user asking, whatever an earlier stop left behind —
        // stopSession() on leaving the app used to swallow the first tap
        // after coming back.
        _leaving = false;
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

  /// Set when the user has asked to stop, so the continuous loop doesn't
  /// immediately reopen the microphone.
  bool _leaving = false;

  /// Ends the session: stops everything and leaves the loop.
  Future<void> stopSession() async {
    _leaving = true;
    _awaitingReply = false;
    await _synthesis.stop();
    await _recognition.cancel();
    await _recognition.releaseMicrophone();
    _chatProvider.cancelCurrentStreaming();
    _setPhase(VoicePhase.idle);
  }

  Future<void> startListening() async {
    // A tap on the orb is a fresh start, and so is the screen opening: the
    // silence budget only counts turns the loop reopened by itself.
    if (_phase == VoicePhase.idle || _phase == VoicePhase.error) {
      _silentTurns = 0;
    }
    if (_leaving) {
      _leaving = false;
      _setPhase(VoicePhase.idle);
      return;
    }

    // Never record while the device is talking, or the recogniser transcribes
    // the assistant's own voice back into the next prompt.
    await _synthesis.stop();

    _archiveTurn();
    error = null;
    transcript = '';
    liveCommitted = '';
    liveTail = '';
    reply = '';
    _spokenUpTo = 0;
    _resetChunks();
    await _recognition.stopWatching();
    // Open for the conversation, not the turn. After the first turn this is
    // already true and returns at once.
    final held = await _recognition.holdMicrophone();
    hearing = held && _heardBefore;
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
    if (isFinal) {
      // Nothing is provisional any more, so the dimmed tail becomes ordinary
      // text rather than sitting there half-faded under the reply.
      liveCommitted = text;
      liveTail = '';
    }
    notifyListeners();
    if (!isFinal) return;

    final prompt = text.trim();
    if (prompt.isEmpty) {
      // A remote backend reports a transcription failure by setting `error`
      // and then handing back an empty final, so the two cases are told
      // apart here: something broke, versus nobody said anything.
      if (error != null) {
        _setPhase(VoicePhase.error);
        return;
      }
      _silentTurns++;
      if (continuousMode && _silentTurns < _maxSilentTurns) {
        // Heard nothing but the conversation is still open — listen again
        // rather than making the user tap to retry.
        unawaited(startListening());
        return;
      }
      endedOnSilence = continuousMode;
      _setPhase(VoicePhase.idle);
      return;
    }
    _silentTurns = 0;
    endedOnSilence = false;
    unawaited(_send(prompt));
  }

  /// Sends a typed prompt through the same path as a spoken one, so the reply
  /// still streams and is still read aloud. For the times when dictation
  /// keeps mishearing a word, or you're somewhere you can't talk.
  Future<void> sendText(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || isBusy) return;
    _leaving = false;
    _silentTurns = 0;

    // Stop any residual playback first, or the previous answer talks over the
    // new one's opening sentence.
    await _synthesis.stop();
    await _recognition.cancel();

    _archiveTurn();
    error = null;
    transcript = prompt;
    liveCommitted = prompt;
    liveTail = '';
    notifyListeners();
    await _send(prompt);
  }

  Future<void> _send(String prompt) async {
    _setPhase(VoicePhase.thinking);
    reply = '';
    _spokenUpTo = 0;
    _resetChunks();
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
    if (_synthesis.isSpeaking) {
      _setPhase(VoicePhase.speaking);
      await _waitForSpeechToFinish();
      return;
    }
    // Nothing left to say: the reply was already spoken while it streamed,
    // or replies are muted. The loop still has to go round — this used to
    // drop to idle with "Tap to talk" and end the conversation.
    _setPhase(VoicePhase.idle);
    if (!continuousMode || _leaving) return;
    await Future.delayed(const Duration(milliseconds: 350));
    if (_phase != VoicePhase.idle) return;
    await startListening();
  }

  Future<void> _waitForSpeechToFinish() async {
    while (_synthesis.isSpeaking && _phase == VoicePhase.speaking) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
    if (_phase != VoicePhase.speaking) return; // interrupted or errored
    _setPhase(VoicePhase.idle);

    if (!continuousMode) return;
    // A beat before reopening the mic: without it the recogniser catches the
    // tail of the device's own audio and transcribes the assistant.
    await Future.delayed(const Duration(milliseconds: 350));
    if (_phase != VoicePhase.idle) return; // user did something meanwhile
    await startListening();
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
    // A chunk that cleans to nothing (a URL, emoji) is never played, so it
    // mustn't count as one — its text rides along with the next chunk.
    if (_synthesis.enqueue(chunk)) _chunkEnds.add(boundary);
    if (_phase == VoicePhase.thinking) _setPhase(VoicePhase.speaking);
  }

  void _flushRemainingSpeech() {
    if (!speakReplies) return;
    if (_spokenUpTo >= reply.length) return;
    final tail = reply.substring(_spokenUpTo);
    _spokenUpTo = reply.length;
    if (_synthesis.enqueue(tail)) _chunkEnds.add(reply.length);
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
