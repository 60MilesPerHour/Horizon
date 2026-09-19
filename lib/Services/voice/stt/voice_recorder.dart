import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:record/record.dart';

import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Services/voice/stt/turn_endpointer.dart';

/// Records a single spoken turn and decides when it ended.
///
/// The decision itself lives in [TurnEndpointer] — this class is the plumbing
/// around it: permissions, the recorder, the file, and the level stream.
///
/// Silero VAD would classify speech more accurately than a level meter, but it
/// arrives via FFI to ONNX Runtime — a new native dependency on all five
/// platforms — and the endpointer's sliding-window floor covers the cases
/// that were actually breaking.
class VoiceRecorder {
  /// Created on first use. Constructing an AudioRecorder initialises the
  /// platform plugin, which is pure cost for anyone on the device recogniser
  /// — and unavailable in tests.
  AudioRecorder? _recorderInstance;
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();

  /// How often the amplitude meter is polled. 100 ms is fine-grained enough
  /// to end a turn promptly without waking the CPU constantly.
  static const Duration _pollInterval = Duration(milliseconds: 100);

  /// Ceiling on the gap credited between two meter frames.
  static const Duration _maxFrameDelta = Duration(seconds: 1);

  /// Silence from the meter itself that means the capture is over, whatever
  /// the recorder thinks.
  ///
  /// `record`'s amplitude stream is a timer that only ticks while it believes
  /// it is recording, and it never reports an error: if the audio session
  /// dies mid-turn — focus lost to a call, a Bluetooth headset connecting —
  /// the frames simply stop. Without this the endpointer is never asked
  /// anything again and the turn sits there until the hard cap.
  static const Duration _meterStallTimeout = Duration(seconds: 3);

  /// Upload the raw WAV instead of compressed audio.
  ///
  /// Compressed is the default because off-LAN the clip crosses a mobile
  /// uplink: the same turn is ~25 KB as 24 kbps AAC against ~260 KB as
  /// 16 kHz WAV, which is most of the delay between finishing a sentence and
  /// the answer starting. Transcripts came back identical from both.
  ///
  /// Kept as an escape hatch because whisper.cpp's bundled `server` decodes
  /// WAV only — anything that shells out to ffmpeg (Speaches,
  /// faster-whisper-server, LocalAI) or any hosted API takes AAC happily.
  bool uploadUncompressed = false;

  StreamSubscription<Amplitude>? _meter;
  Timer? _deadline;
  Completer<_TurnOutcome>? _turn;
  TurnEndpointer? _endpointer;

  /// Live microphone level, 0..1, for the UI to show that it's hearing
  /// something. With a remote backend there are no partial words to display,
  /// so this is the only feedback the user gets.
  final StreamController<double> _levels = StreamController<double>.broadcast();
  Stream<double> get levels => _levels.stream;

  bool get isRecording => _turn != null && !_turn!.isCompleted;

  /// How much speech the last turn contained, or null when the turn was kept
  /// without speech ever being detected — a manual stop somewhere too loud to
  /// tell the two apart.
  ///
  /// Null means "no basis to judge the transcript", not "no speech": a caller
  /// that treats it as zero throws away exactly the turns the manual stop
  /// exists to rescue.
  Duration? lastTurnSpeechDuration;

  /// Set when the last turn had to be ended because the level never dropped
  /// back to the room — somewhere too loud to hear the end of a sentence.
  bool lastTurnEndedOnNoise = false;

  /// The room level measured during the last turn, in dBFS, or null if no
  /// turn has run.
  ///
  /// Read to decide whether to warn: above about -22 dBFS the ambience is
  /// within a few dB of an ordinary speaking voice, which is where level
  /// metering stops being able to hear a sentence end at all and turns start
  /// getting cut mid-word.
  double? lastTurnRoomDb;

  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// Records until the speaker stops, and returns the audio path — or null if
  /// nothing was said, permission was refused, or [cancel] was called.
  Future<String?> recordTurn() async {
    if (isRecording) return null;
    if (!await hasPermission()) return null;

    final directory = await _recordingsDirectory();
    final encoder = await _chooseEncoder();
    final file = path.join(
      directory.path,
      'turn_${DateTime.now().microsecondsSinceEpoch}.${_extensionFor(encoder)}',
    );

    try {
      await _recorder.start(_configFor(encoder), path: file);
    } catch (_) {
      return null;
    }

    final turn = Completer<_TurnOutcome>();
    _turn = turn;

    final endpointer = TurnEndpointer(frame: _pollInterval);
    _endpointer = endpointer;
    lastTurnSpeechDuration = null;
    lastTurnEndedOnNoise = false;
    lastTurnRoomDb = null;

    // Real time between meter frames, rather than trusting the interval we
    // asked for: platforms deliver on their own schedule, and every timeout
    // in the endpointer is denominated in these.
    final since = Stopwatch()..start();
    final total = Stopwatch()..start();

    // Ends the turn on the endpointer's strict terms if the meter stops
    // delivering, or if the whole thing overruns. Strict deliberately: a turn
    // that ends because capture broke has no speech to vouch for it, and
    // uploading a minute of whatever the microphone caught puts a
    // hallucinated transcript in front of the model as if it were a question.
    _deadline = Timer.periodic(const Duration(seconds: 1), (_) {
      if (turn.isCompleted) return;
      final stalled = since.elapsed > _meterStallTimeout;
      final overrun = total.elapsed >
          TurnEndpointer.maxTurn + const Duration(seconds: 5);
      if (!stalled && !overrun) return;
      turn.complete(endpointer.worthUploading
          ? _TurnOutcome.ended
          : _TurnOutcome.silent);
    });

    _meter = _recorder.onAmplitudeChanged(_pollInterval).listen((amplitude) {
      // Bounded: a frozen app or a stalled meter shouldn't hand the
      // endpointer a several-second jump, and a burst of frames shouldn't
      // report zero elapsed time either.
      final measured = since.elapsed;
      since.reset();
      final delta = measured < _pollInterval ~/ 4
          ? _pollInterval ~/ 4
          : (measured > _maxFrameDelta ? _maxFrameDelta : measured);

      // `current` is dBFS: 0 is clipping, about -60 is silence. On Android
      // it's the frame peak rather than RMS, which the endpointer smooths.
      final signal = endpointer.add(amplitude.current, delta: delta);
      _levels.add(endpointer.level);

      if (turn.isCompleted) return;
      switch (signal) {
        case TurnSignal.listening:
          break;
        case TurnSignal.ended:
          turn.complete(_TurnOutcome.ended);
        case TurnSignal.silent:
          turn.complete(_TurnOutcome.silent);
      }
    }, onError: (_) {
      if (turn.isCompleted) return;
      turn.complete(endpointer.worthUploading
          ? _TurnOutcome.ended
          : _TurnOutcome.silent);
    });

    final outcome = await turn.future;
    await _teardown();

    lastTurnSpeechDuration =
        endpointer.speechHeard ? endpointer.speechDuration : null;
    lastTurnEndedOnNoise = endpointer.endedOnNoise;
    lastTurnRoomDb = endpointer.noiseFloorDb;

    final recorded = await _stopRecorder();
    if (outcome != _TurnOutcome.ended || recorded == null) {
      await _discard(recorded);
      return null;
    }
    return recorded;
  }

  /// Ends the turn now and keeps what was recorded — the user tapping "stop".
  void finish() {
    final turn = _turn;
    if (turn == null || turn.isCompleted) return;
    // The endpointer decides whether there is anything worth uploading; on a
    // deliberate stop it keeps any recording of a plausible length, detected
    // speech or not.
    final signal = _endpointer?.finishNow() ?? TurnSignal.ended;
    turn.complete(
      signal == TurnSignal.ended ? _TurnOutcome.ended : _TurnOutcome.silent,
    );
  }

  /// Ends the turn and throws the audio away.
  void cancel() {
    final turn = _turn;
    if (turn != null && !turn.isCompleted) turn.complete(_TurnOutcome.cancelled);
  }

  Future<void> dispose() async {
    cancel();
    await _teardown();
    try {
      await _recorderInstance?.dispose();
    } catch (_) {}
    _recorderInstance = null;
    await _levels.close();
  }

  /// 16 kHz mono, and AAC unless [uploadUncompressed] says otherwise: 16 kHz
  /// is what Whisper resamples to anyway, and mono halves the upload again.
  ///
  /// `autoGain` is deliberately **off**. Android's AutomaticGainControl
  /// effect normalises the capture level, which means it lifts room noise in
  /// the gaps between words — it flattens exactly the contrast the endpointer
  /// reads, and it was on. Echo cancellation and noise suppression stay on;
  /// they help a phone held at arm's length and they don't fight the meter.
  RecordConfig _configFor(AudioEncoder encoder) => RecordConfig(
        encoder: encoder,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 24000,
        autoGain: false,
        echoCancel: true,
        noiseSuppress: true,
        androidConfig: const AndroidRecordConfig(
          // Tuned for recognition: the platform leaves its own gain control
          // out of this path, which is what we want for both the transcript
          // and the level meter.
          audioSource: AndroidAudioSource.voiceRecognition,
        ),
      );

  Future<AudioEncoder> _chooseEncoder() async {
    if (uploadUncompressed) return AudioEncoder.wav;
    try {
      if (await _recorder.isEncoderSupported(AudioEncoder.aacLc)) {
        return AudioEncoder.aacLc;
      }
    } catch (_) {
      // A platform that can't answer is a platform that gets WAV.
    }
    return AudioEncoder.wav;
  }

  static String _extensionFor(AudioEncoder encoder) =>
      encoder == AudioEncoder.aacLc ? 'm4a' : 'wav';

  Future<void> _teardown() async {
    await _meter?.cancel();
    _meter = null;
    _deadline?.cancel();
    _deadline = null;
    _turn = null;
    _endpointer = null;
  }

  Future<String?> _stopRecorder() async {
    try {
      return await _recorder.stop();
    } catch (_) {
      return null;
    }
  }

  Future<void> _discard(String? filePath) async {
    if (filePath == null) return;
    try {
      final file = File(filePath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Turn audio is transient — it's uploaded, transcribed, and deleted. Any
  /// file left behind by a crash is cleared out on the next recording rather
  /// than accumulating silently.
  Future<Directory> _recordingsDirectory() async {
    final directory = Directory(path.join(
      PathManager.instance.documentsDirectory.path,
      'voice_turns',
    ));
    await directory.create(recursive: true);
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in directory.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await entity.delete();
      }
    } catch (_) {}
    return directory;
  }
}

enum _TurnOutcome { ended, silent, cancelled }
