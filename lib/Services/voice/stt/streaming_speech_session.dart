import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:horizon/Services/voice/stt/mic_pcm_stream.dart';
import 'package:horizon/Services/voice/stt/turn_endpointer.dart';
import 'package:horizon/Services/voice/stt/whisper_live_client.dart';

/// How a streaming turn finished.
enum StreamingTurnOutcome {
  /// Someone spoke and there is a transcript.
  spoken,

  /// The microphone was open but nothing was said.
  silent,

  /// Abandoned — the user left, or the session was replaced.
  cancelled,

  /// The live server could not be used. The caller should fall back to
  /// recording the turn and uploading it.
  unavailable,
}

/// The result of one streaming turn.
class StreamingTurn {
  const StreamingTurn(
    this.outcome, {
    this.text = '',
    this.audio,
    this.serverLost = false,
    this.clip,
  });

  final StreamingTurnOutcome outcome;
  final String text;

  /// The captured turn as a 16-bit WAV, kept only when there is a reason to
  /// send it somewhere else: the live transcript came back empty even though
  /// speech was heard, so the whole clip is worth one accurate pass.
  final Uint8List? audio;

  /// True when the live server never became usable, or dropped mid-turn, and
  /// [audio] is the whole turn rather than a backstop for an empty transcript.
  final bool serverLost;

  /// For a turn with a live transcript: the stretch of audio where the
  /// speaker's voice was actually present, as a WAV, for one accurate pass.
  /// The live words came from a small model on a sliding window; this lets a
  /// bigger one have the final say, without the room noise either side.
  final Uint8List? clip;
}

/// Where the live server is, from the point of view of one turn.
enum _Server { connecting, live, lost }

/// One spoken turn, transcribed while it is being spoken.
///
/// This is the new shape of voice input, and it inverts the old one. The
/// file path recorded a turn, decided it was over, uploaded it, and *then*
/// got words — so the user watched a level meter wobble and then waited. Here
/// the microphone, the endpointer and the recogniser all run at once: words
/// appear about a second behind the voice, the turn still ends by itself, and
/// by the time it ends the transcript is already nearly complete.
///
/// Three jobs, kept separate on purpose:
///  - [MicPcmStream] captures and measures;
///  - [TurnEndpointer] — unchanged, and still the thing that decides a turn
///    is over, because it is tuned and tested against noisy rooms and a
///    server's VAD is a round trip away;
///  - [WhisperLiveClient] turns audio into revisable text.
///
/// Also keeps every frame it sends, because a live transcript is a hypothesis
/// and occasionally the session dies mid-sentence. Holding the PCM means a
/// broken turn can still be transcribed accurately from the clip instead of
/// being lost, which is the one thing voice input must never do.
class StreamingSpeechSession {
  StreamingSpeechSession({required this.mic, required this.client});

  final MicPcmStream mic;
  final WhisperLiveClient client;

  /// Frames stop arriving when the audio session is taken away — a call, a
  /// headset connecting — and `record` reports that by simply going quiet.
  /// Same watchdog, same reason, as the file path.
  static const Duration _micStallTimeout = Duration(seconds: 3);

  /// Beyond this the turn ends regardless. Matches the file path's cap.
  static Duration get maxTurn => TurnEndpointer.maxTurn;

  /// The fast path: the microphone has heard this much quiet since the last
  /// syllable *and* the words have stopped changing for [_quietSettle]. Two
  /// independent signals agreeing is what lets a turn end in about half a
  /// second without cutting anyone off — neither is trusted alone at that
  /// speed.
  static const Duration _quietFor = Duration(milliseconds: 450);
  static const Duration _quietSettle = Duration(milliseconds: 250);

  /// Words unchanged this long, with the microphone at least briefly quiet,
  /// is a finished turn even when the meter's hangover hasn't run out.
  static const Duration _transcriptSettle = Duration(milliseconds: 900);
  static const Duration _briefQuiet = Duration(milliseconds: 200);

  /// Words unchanged this long end the turn whatever the meter says. The
  /// loud-room path: at 0 dB SNR the meter can't hear a voice stop, but the
  /// server — Silero VAD plus Whisper on the real audio — can, and it was
  /// measured returning the sentence under babble louder than the speaker.
  ///
  /// Not the primary signal, because while the server is catching up on a
  /// backlog it repeats the same hypothesis with the speaker still talking —
  /// which is exactly what cut people off when words alone decided.
  static const Duration _loudRoomSettle = Duration(milliseconds: 2000);

  /// Extra patience after a transcript that ends mid-thought.
  static const Duration _hesitationExtra = Duration(milliseconds: 1500);

  static final RegExp _hesitation = RegExp(
    r"\b(um+|uh+|er+|hmm+|so|and|but|or|like|because|the|a|an|to|of|with)"
    r"[\s,.…-]*$",
    caseSensitive: false,
  );

  static bool _hesitating(String text) =>
      text.trimRight().endsWith(',') ||
      text.trimRight().endsWith('...') ||
      text.trimRight().endsWith('…') ||
      _hesitation.hasMatch(text);

  /// Repeats of an unchanged hypothesis needed before [_transcriptSettle]
  /// counts. Proves the server is still listening rather than stalled on the
  /// network, which would otherwise look exactly like a speaker who stopped.
  static const int _confirmations = 2;

  /// Audio after the server became ready with no words in it before the turn
  /// is called silent.
  static const Duration _noWordsTimeout = TurnEndpointer.noSpeechTimeout;

  StreamSubscription<Float32List>? _frames;
  StreamSubscription<LiveTranscript>? _updates;
  StreamSubscription<String>? _clientErrors;
  Timer? _watchdog;
  Completer<StreamingTurn>? _turn;
  TurnEndpointer? _endpointer;
  final List<Float32List> _captured = [];
  DateTime _lastFrame = DateTime.now();
  bool _sawSpeech = false;

  _Server _server = _Server.connecting;
  bool _canRecover = false;
  Duration _readyAt = Duration.zero;
  String _lastText = '';
  Duration _textChangedAt = Duration.zero;
  int _repeats = 0;
  bool _energyEnded = false;
  bool _energySilent = false;

  /// Where the speaker's voice starts and stops in [_captured], by the level
  /// meter: the nearest, loudest voice is the one holding the phone. Null
  /// when the meter never heard speech — a room too loud to tell — in which
  /// case the whole capture is used.
  Duration? _voiceStart;
  Duration? _voiceEnd;

  /// When the microphone last heard something well above the room — speech
  /// or not. Holds off the no-words timeout while anything is happening.
  Duration _lastSoundAt = Duration.zero;
  static const Duration _soundGrace = Duration(milliseconds: 1500);
  static const Duration _noWordsHardCap = Duration(seconds: 15);

  /// dB over the room that counts as "something is happening".
  static const double _soundMargin = 10;

  // Diagnostics only.
  DateTime _startedAt = DateTime.now();
  Duration? _firstFrameAfter;
  double _peakDb = MicPcmStream.silenceDb;

  final StreamController<double> _levels = StreamController<double>.broadcast();

  /// Microphone level, 0..1, for the meter that sits under the live text.
  /// Still worth showing with words on screen: it is the only thing that
  /// distinguishes "still listening" from "heard nothing at all".
  Stream<double> get levels => _levels.stream;

  final StreamController<void> _onsets = StreamController<void>.broadcast();

  /// Fires the moment sustained speech starts. The point of a session that
  /// keeps listening while the assistant talks: this is what lets talking
  /// over it actually interrupt it.
  Stream<void> get speechOnsets => _onsets.stream;

  bool get isRunning => _turn != null && !_turn!.isCompleted;

  StreamSubscription<Float32List>? _watcher;
  bool get isWatching => _watcher != null;

  /// True when the live server was reachable for this turn.
  bool get isLive => client.isConnected;

  /// Everything heard so far, committed text plus revisable tail.
  LiveTranscript get transcript => client.current;

  /// Runs one turn to completion.
  ///
  /// The microphone opens first and the server connects behind it. The old
  /// order — connect, wait for SERVER_READY, *then* open the mic — cost the
  /// first words of every turn: a cold WhisperLive takes over five seconds to
  /// load its model, and people start talking the moment the screen says
  /// "Listening". Frames captured while connecting are held and flushed the
  /// instant the server is ready, so it transcribes them like any others.
  ///
  /// [onPartial] fires on every revision, which is roughly every 100-200 ms
  /// while someone is speaking.
  ///
  /// [canRecover] says whether the caller can transcribe a captured clip
  /// some other way. If it can, a server that never answers doesn't end the
  /// turn: the level meter decides when it's over and the clip is handed
  /// back. If it can't, the turn returns [StreamingTurnOutcome.unavailable]
  /// as soon as the server is known to be unreachable.
  Future<StreamingTurn> run({
    required void Function(LiveTranscript transcript) onPartial,
    String? languageCode,
    bool canRecover = false,
  }) async {
    // A turn still running is replaced, not refused: refusing left a new
    // voice page waiting on a turn that was never going to start.
    if (isRunning) cancel();
    // And a turn that has ended but is still settling is waited for. Settling
    // tears down the session's subscriptions and socket; starting over the top
    // of it had the old teardown wipe the new turn — its future never
    // resolved and its microphone could never be stopped.
    final settling = _settling;
    if (settling != null) await settling;
    // The onset watcher holds the same microphone, so it has to let go first.
    await stopWatching();

    _cancelPending = false;
    _starting = true;
    try {
      // Held open for the session: no permission round-trip, no reopening,
      // and none of the call-audio path's muted warm-up.
      if (!_held) {
        if (!await mic.hasPermission()) {
          return const StreamingTurn(StreamingTurnOutcome.unavailable);
        }
        if (!await mic.start()) {
          return const StreamingTurn(StreamingTurnOutcome.unavailable);
        }
      }
    } finally {
      _starting = false;
    }
    // Cancelled while the microphone was opening: there was no turn yet for
    // cancel() to end, so it left a note instead.
    if (_cancelPending) {
      _cancelPending = false;
      if (!_held) await mic.stop();
      return const StreamingTurn(StreamingTurnOutcome.cancelled);
    }

    final turn = Completer<StreamingTurn>();
    _turn = turn;
    _captured.clear();
    _sawSpeech = false;
    _lastFrame = DateTime.now();
    _server = _Server.connecting;
    _canRecover = canRecover;
    _readyAt = Duration.zero;
    _lastText = '';
    _textChangedAt = Duration.zero;
    _repeats = 0;
    _energyEnded = false;
    _energySilent = false;
    _voiceStart = null;
    _voiceEnd = null;
    _startedAt = DateTime.now();
    _lastSoundAt = Duration.zero;
    _firstFrameAfter = null;
    _peakDb = MicPcmStream.silenceDb;
    _turnAudio = Duration.zero;

    final endpointer = TurnEndpointer();
    _endpointer = endpointer;

    _updates = client.transcripts.listen((t) {
      if (turn.isCompleted) return;
      final text = WhisperLiveClient.isFiller(t.text) ? '' : t.text;
      if (text != _lastText) {
        _lastText = text;
        _textChangedAt = _turnAudio;
        _repeats = 0;
      } else {
        _repeats++;
      }
      if (text.isNotEmpty && !_sawSpeech) {
        _sawSpeech = true;
        if (!_onsets.isClosed) _onsets.add(null);
      }
      onPartial(t);
    });

    _clientErrors = client.errors.listen((message) {
      debugPrint('voice: live server: $message');
      // A live session that fails mid-turn is not a lost turn: the frames are
      // in hand, so the level meter takes over and the caller transcribes the
      // clip. Errors raised while still connecting are the connect path's to
      // handle.
      if (turn.isCompleted || _server != _Server.live) return;
      _loseServer();
    });

    void onFrame(Float32List frame) {
      if (turn.isCompleted) return;
      _lastFrame = DateTime.now();
      if (_captured.isEmpty) {
        _firstFrameAfter = DateTime.now().difference(_startedAt);
      }
      _peakDb = math.max(_peakDb, MicPcmStream.rmsDb(frame));
      _captured.add(frame);
      if (_server == _Server.live) client.send(frame);

      // Audio time, not wall-clock: every endpointer timeout is denominated
      // in how much sound actually arrived, and a frame is exactly as long as
      // the samples in it.
      final delta = Duration(
        microseconds:
            frame.length * Duration.microsecondsPerSecond ~/ MicPcmStream.sampleRate,
      );
      _turnAudio += delta;
      final signal = endpointer.add(MicPcmStream.rmsDb(frame), delta: delta);
      if (!_levels.isClosed) _levels.add(endpointer.level);
      if (MicPcmStream.rmsDb(frame) >= endpointer.noiseFloorDb + _soundMargin) {
        _lastSoundAt = _turnAudio;
      }

      if (!_sawSpeech && endpointer.speechHeard) {
        _sawSpeech = true;
        if (!_onsets.isClosed) _onsets.add(null);
      }

      if (endpointer.speechHeard) {
        // Latching takes sustained speech, so the voice began a little
        // before the meter was sure of it.
        _voiceStart ??= _turnAudio - const Duration(milliseconds: 500);
        if (endpointer.quietFor == Duration.zero) _voiceEnd = _turnAudio;
      }
      if (signal == TurnSignal.ended) _energyEnded = true;
      if (signal == TurnSignal.silent) _energySilent = true;
      _decide();
    }

    // What was heard just before the turn began — the start of a sentence
    // spoken as the screen changed to "Listening" — goes first.
    final preroll = List<Float32List>.of(_preroll);
    _preroll.clear();
    for (final frame in preroll) {
      onFrame(frame);
    }
    _frames = mic.frames.listen(onFrame, onError: (_) {
      _complete(_hasSomething
          ? StreamingTurnOutcome.spoken
          : StreamingTurnOutcome.silent);
    });

    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (turn.isCompleted) return;
      final stalled =
          DateTime.now().difference(_lastFrame) > _micStallTimeout;
      final overrun = _turnAudio > maxTurn + const Duration(seconds: 5);
      if (!stalled && !overrun) return;
      _complete(_hasSomething
          ? StreamingTurnOutcome.spoken
          : StreamingTurnOutcome.silent);
    });

    final previous = _connecting;
    _connecting = _connect(turn, languageCode, after: previous);
    return turn.future;
  }

  /// The connect behind the current or most recent turn. A turn can end
  /// while its connect is still waiting on a cold server; the next one has to
  /// wait for that to settle, or two handshakes race over one client.
  Future<void>? _connecting;

  Future<void> _connect(
    Completer<StreamingTurn> turn,
    String? languageCode, {
    Future<void>? after,
  }) async {
    if (after != null) await after;
    if (turn.isCompleted) return;
    final ok = await client.connect(languageCode: languageCode);
    if (turn.isCompleted) {
      // Ended while the server was loading. Settling has already run, so
      // this session is nobody's; close it rather than hold a model slot.
      if (ok) await client.close();
      return;
    }
    if (!ok) {
      if (!_canRecover) {
        _complete(StreamingTurnOutcome.unavailable);
        return;
      }
      _loseServer();
      return;
    }
    // Everything said while the model loaded goes up in one go. Single
    // threaded, so no frame can slip in between the flush and the flag.
    for (final frame in _captured) {
      client.send(frame);
    }
    _server = _Server.live;
    _readyAt = _turnAudio;
    debugPrint('voice: live ready after ${_turnAudio.inMilliseconds}ms of '
        'audio, flushed ${_captured.length} frames');
  }

  void _loseServer() {
    _server = _Server.lost;
    _decide();
  }

  /// Whether the turn has anything in it worth handing back.
  bool get _hasSomething =>
      _lastText.isNotEmpty || (_endpointer?.worthUploading ?? false);

  /// Ends the turn when the evidence says it's over.
  ///
  /// While the server is live, the words decide and the level meter only
  /// helps: the meter's "silent" is ignored once words exist (it can't hear
  /// speech in a loud room, the server can), and its "ended" only shortens
  /// the wait for a transcript that has already stopped changing. Without a
  /// server the meter is all there is, as before.
  void _decide() {
    switch (_server) {
      case _Server.connecting:
        // Nothing to judge the words by yet, and the audio is being kept, so
        // there is no cost to waiting for the server to catch up.
        return;

      case _Server.lost:
        if (_energyEnded) {
          _complete(StreamingTurnOutcome.spoken);
        } else if (_energySilent) {
          _complete(_lastText.isNotEmpty
              ? StreamingTurnOutcome.spoken
              : StreamingTurnOutcome.silent);
        }
        return;

      case _Server.live:
        final now = _turnAudio;
        if (_lastText.isEmpty) {
          // Never while the microphone is hearing something. A recorded turn
          // showed why: speech starting at 5.8 s was cut off at 8 s, a second
          // before the server's first words for it would have arrived.
          // ...but not forever either: a television is sound without words,
          // and it shouldn't hold the microphone open to the hard cap.
          final soundRecently = now - _lastSoundAt < _soundGrace;
          final waited = now - _readyAt;
          if ((waited >= _noWordsTimeout && !soundRecently) ||
              waited >= _noWordsHardCap) {
            _complete(StreamingTurnOutcome.silent);
          }
          return;
        }
        final stable = now - _textChangedAt;
        final quiet = _endpointer?.quietFor ?? Duration.zero;
        // Trailing off on "um" or "so" is someone thinking, not finishing —
        // being cut off mid-thought is the complaint every voice assistant
        // gets, so every path waits longer after one.
        final extra =
            _hesitating(_lastText) ? _hesitationExtra : Duration.zero;
        final fast = quiet >= _quietFor + extra && stable >= _quietSettle;
        final settled = _repeats >= _confirmations &&
            quiet >= _briefQuiet &&
            stable >= _transcriptSettle + extra;
        final loud = _repeats >= _confirmations &&
            stable >= _loudRoomSettle + extra;
        if (fast || settled || loud) _complete(StreamingTurnOutcome.spoken);
    }
  }

  /// The user said they were finished. Keeps whatever was captured, on the
  /// endpointer's terms — which on a deliberate stop are generous, because
  /// somewhere too loud to hear a sentence end is exactly where this is the
  /// only way to end one.
  void finish() {
    final endpointer = _endpointer;
    if (endpointer == null) return;
    final signal = endpointer.finishNow();
    _complete(signal == TurnSignal.ended || _lastText.isNotEmpty
        ? StreamingTurnOutcome.spoken
        : StreamingTurnOutcome.silent);
  }

  void cancel() {
    if (_turn == null && _starting) {
      _cancelPending = true;
      return;
    }
    _complete(StreamingTurnOutcome.cancelled);
  }

  bool _starting = false;
  bool _cancelPending = false;

  /// Audio this turn has received, pre-roll included. The microphone's own
  /// counter runs across the whole session once it's held open, so every
  /// per-turn timeout is measured against this instead.
  Duration _turnAudio = Duration.zero;

  // ---------------------------------------------------------------------
  // Holding the microphone open for a whole conversation.
  //
  // Reopening it every turn cost about a second each time: half a second
  // for the first audio to arrive and another few hundred milliseconds of
  // near-silence while the call path's processing warmed up — measured at
  // -82 to -85 dBFS, below any real room. Whatever was said in that second
  // was simply never recorded, which is what "it doesn't get the first few
  // words" was. Held open, a turn starts on audio already flowing, with a
  // short pre-roll of what came just before it.

  bool _held = false;
  bool get isHeld => _held;
  StreamSubscription<Float32List>? _holdFrames;
  final List<Float32List> _preroll = [];
  int _prerollSamples = 0;
  static const int _prerollMax = MicPcmStream.sampleRate; // one second

  /// True while the assistant is talking. Nothing heard then goes into the
  /// pre-roll, or the next turn would open with the assistant's own voice.
  bool _echoing = false;
  set echoing(bool value) {
    if (value == _echoing) return;
    _echoing = value;
    _preroll.clear();
    _prerollSamples = 0;
  }

  Future<bool> hold() async {
    if (_held) return true;
    if (!await mic.hasPermission()) return false;
    if (!await mic.start()) return false;
    _held = true;
    _holdFrames = mic.frames.listen((frame) {
      // During a turn the turn itself has the frames; between turns they
      // are kept briefly in case one is about to start.
      if (isRunning || _echoing) return;
      _preroll.add(frame);
      _prerollSamples += frame.length;
      while (_prerollSamples > _prerollMax && _preroll.length > 1) {
        _prerollSamples -= _preroll.removeAt(0).length;
      }
    });
    return true;
  }

  Future<void> release() async {
    if (!_held) return;
    _held = false;
    await _holdFrames?.cancel();
    _holdFrames = null;
    _preroll.clear();
    _prerollSamples = 0;
    if (!isRunning && !isWatching) await mic.stop();
  }

  /// The settle of the most recent turn, while it is still running.
  Future<void>? _settling;

  /// Opens the microphone to listen for *someone starting to talk*, and
  /// nothing else: no socket, no transcription, no audio kept. This is what
  /// makes talking over the assistant interrupt it.
  ///
  /// The honest caveat is acoustic, not technical. While the assistant is
  /// speaking through a phone's loudspeaker, its own voice is in the
  /// microphone, and platform echo cancellation is the only thing standing
  /// between that and a self-interrupt. The endpointer's adaptive floor
  /// happens to help a great deal here — it rises to treat the assistant's
  /// voice as the room, so a real interruption has to beat *that* by the
  /// attack margin rather than beating silence — but on a loud speaker with
  /// weak AEC it will still trigger on itself, which is why this is opt-in
  /// and reads best with headphones.
  Future<bool> watchForOnset({required void Function() onSpeech}) async {
    if (isRunning || isWatching) return false;
    if (!await mic.hasPermission()) return false;
    if (!await mic.start()) return false;

    final endpointer = TurnEndpointer();
    _watcher = mic.frames.listen((frame) {
      final delta = Duration(
        microseconds:
            frame.length * Duration.microsecondsPerSecond ~/ MicPcmStream.sampleRate,
      );
      endpointer.add(MicPcmStream.rmsDb(frame), delta: delta);
      if (!_levels.isClosed) _levels.add(endpointer.level);
      if (!endpointer.speechHeard) return;
      // Stop before the callback: it will typically start a real turn, and
      // that turn needs the microphone this subscription is holding.
      unawaited(stopWatching().then((_) => onSpeech()));
    }, onError: (_) => unawaited(stopWatching()));
    return true;
  }

  /// Closes the onset watcher, if one is open. Safe to call at any time.
  Future<void> stopWatching() async {
    final watcher = _watcher;
    if (watcher == null) return;
    _watcher = null;
    await watcher.cancel();
    if (!isRunning && !_held) await mic.stop();
  }

  Future<void> dispose() async {
    cancel();
    await stopWatching();
    await _teardown();
    await mic.dispose();
    await client.dispose();
    if (!_levels.isClosed) await _levels.close();
    if (!_onsets.isClosed) await _onsets.close();
  }

  void _complete(StreamingTurnOutcome outcome) {
    final turn = _turn;
    if (turn == null || turn.isCompleted) return;
    // Completed before the async settle so nothing else can end the turn
    // twice while the last words are still arriving.
    final settle = _settle(outcome);
    late final Future<void> done;
    done = settle.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_settling, done)) _settling = null;
    });
    _settling = done;
    turn.complete(settle);
  }

  Future<StreamingTurn> _settle(StreamingTurnOutcome outcome) async {
    if (!_held) await mic.stop();
    await _frames?.cancel();
    _frames = null;
    _logTurn(outcome);

    if (outcome == StreamingTurnOutcome.cancelled) {
      await _teardown();
      await client.close();
      return const StreamingTurn(StreamingTurnOutcome.cancelled);
    }

    if (outcome == StreamingTurnOutcome.unavailable) {
      await _teardown();
      await client.close();
      return const StreamingTurn(StreamingTurnOutcome.unavailable);
    }

    // The server is still a window behind the speaker, so the closing words
    // of the sentence are transcribed after the microphone is already shut.
    final lost = _server != _Server.live;
    final result = lost
        ? client.current
        : await client.finish(
            settle: const Duration(milliseconds: 250),
            grace: const Duration(milliseconds: 1200),
          );
    final heardSpeech = _endpointer?.worthUploading ?? false;
    final audio = _captured.isEmpty ? null : MicPcmStream.toWav(_captured);

    await _teardown();
    await client.close();

    if (outcome == StreamingTurnOutcome.silent) {
      return const StreamingTurn(StreamingTurnOutcome.silent);
    }
    if (lost && (_canRecover || result.text.isEmpty)) {
      // The server never got the whole turn, so whatever partial text it
      // produced is a fragment. The clip is the complete record — unless
      // nothing can transcribe it, in which case the fragment is better
      // than nothing.
      return audio == null
          ? const StreamingTurn(StreamingTurnOutcome.silent)
          : StreamingTurn(
              StreamingTurnOutcome.spoken,
              audio: audio,
              serverLost: true,
            );
    }
    if (result.isEmpty) {
      // Speech was heard but no words came back: the session dropped, or the
      // server was still loading. Hand the clip up for one accurate pass
      // rather than pretending nobody said anything.
      return heardSpeech
          ? StreamingTurn(StreamingTurnOutcome.spoken, audio: audio)
          : const StreamingTurn(StreamingTurnOutcome.silent);
    }
    return StreamingTurn(
      StreamingTurnOutcome.spoken,
      text: result.text,
      clip: _voiceClip(),
    );
  }

  /// The captured turn cut to the speaker's voice, with a margin either side
  /// so a soft first or last syllable isn't clipped. Background talk before
  /// you started and after you finished is what Whisper turns into words you
  /// never said; outside the span, it never reaches it.
  Uint8List? _voiceClip() {
    if (_captured.isEmpty) return null;
    const margin = Duration(milliseconds: 350);
    final start = _voiceStart;
    final end = _voiceEnd;
    if (start == null || end == null || end <= start) {
      return MicPcmStream.toWav(_captured);
    }
    final from = _sampleAt(start - margin);
    final to = _sampleAt(end + margin);
    final frames = <Float32List>[];
    var position = 0;
    for (final frame in _captured) {
      final frameEnd = position + frame.length;
      if (frameEnd > from && position < to) {
        final a = (from - position).clamp(0, frame.length);
        final b = (to - position).clamp(0, frame.length);
        frames.add(Float32List.sublistView(frame, a, b));
      }
      position = frameEnd;
    }
    return frames.isEmpty ? null : MicPcmStream.toWav(frames);
  }

  static int _sampleAt(Duration at) => at.isNegative
      ? 0
      : at.inMicroseconds * MicPcmStream.sampleRate ~/ Duration.microsecondsPerSecond;

  /// One line per turn saying what the microphone actually delivered, and in
  /// test builds a copy of the audio: a word that never made it into the
  /// capture and a word the recogniser missed look identical from the UI,
  /// and only the recording tells them apart.
  void _logTurn(StreamingTurnOutcome outcome) {
    debugPrint('voice: mic first audio after '
        '${_firstFrameAfter?.inMilliseconds ?? -1}ms, '
        'captured ${_turnAudio.inMilliseconds}ms, '
        'peak ${_peakDb.toStringAsFixed(1)} dBFS, '
        'floor ${_endpointer?.noiseFloorDb.toStringAsFixed(1)} dBFS, '
        'meter heard speech=${_endpointer?.speechHeard}, '
        'words="${_lastText.length > 60 ? '${_lastText.substring(0, 60)}…' : _lastText}", '
        'outcome=${outcome.name}');
    if (kProfileMode && _captured.isNotEmpty) {
      unawaited(_keepForDebugging(MicPcmStream.toWav(_captured), outcome));
    }
  }

  /// Profile (test) builds only, and only the last ten turns. Written to the
  /// app's external files directory so `adb pull` can reach it; never in a
  /// release build, because these are recordings of the user's voice.
  static Future<void> _keepForDebugging(
    Uint8List wav,
    StreamingTurnOutcome outcome,
  ) async {
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) return;
      final dir = Directory('${base.path}/voice_debug');
      await dir.create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      await File('${dir.path}/$stamp-${outcome.name}.wav').writeAsBytes(wav);
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final old in files.take(math.max(0, files.length - 10))) {
        await old.delete();
      }
    } catch (_) {}
  }

  Future<void> _teardown() async {
    _watchdog?.cancel();
    _watchdog = null;
    await _frames?.cancel();
    _frames = null;
    await _updates?.cancel();
    _updates = null;
    await _clientErrors?.cancel();
    _clientErrors = null;
    _endpointer = null;
    _turn = null;
  }
}
