import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as path;
import 'package:record/record.dart';

import 'package:horizon/Constants/constants.dart';

/// Records a single spoken turn and decides when it ended.
///
/// The remote transcription backends need a finished clip, which makes
/// endpointing our problem rather than the recogniser's. This uses the
/// recorder's own amplitude meter: speech is detected when the level rises
/// above a noise floor measured at the start of the turn, and the turn ends
/// after a short run of silence.
///
/// Silero VAD would be more accurate, but it arrives via FFI to ONNX Runtime
/// — a new native dependency on all four platforms — and an energy gate is
/// enough to beat the alternative, which is a fixed timeout that both cuts
/// people off mid-thought and adds dead air to every single reply.
class VoiceRecorder {
  /// Created on first use. Constructing an AudioRecorder initialises the
  /// platform plugin, which is pure cost for anyone on the device recogniser
  /// — and unavailable in tests.
  AudioRecorder? _recorderInstance;
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();

  /// How often the amplitude meter is polled. 100 ms is fine-grained enough
  /// to end a turn promptly without waking the CPU constantly.
  static const Duration _pollInterval = Duration(milliseconds: 100);

  /// Silence needed to end the turn once speech has been heard. Long enough
  /// to survive the pause in "the answer is… four", short enough to feel
  /// immediate. Far tighter than the platform recogniser's 3 s default.
  static const Duration _endpointSilence = Duration(milliseconds: 900);

  /// Give up if nobody says anything at all.
  static const Duration _noSpeechTimeout = Duration(seconds: 8);

  /// Hard cap on a single turn, so a stuck-open microphone can't record
  /// forever and then upload it.
  static const Duration _maxTurn = Duration(seconds: 90);

  /// How far above the measured noise floor counts as speech, in dB.
  static const double _speechMargin = 9.0;

  /// Frames used to measure the room before deciding what silence sounds
  /// like. A fixed threshold fails in both directions: too high in a quiet
  /// room, too low next to a fan.
  static const int _calibrationFrames = 4;

  /// Ceiling on the measured noise floor, in dBFS.
  ///
  /// People start talking the instant they tap the microphone, so the
  /// calibration frames often contain speech rather than room tone. Left
  /// uncapped, the floor lands somewhere near speaking volume, nothing
  /// afterwards clears floor + margin, and the turn ends on the no-speech
  /// timeout having thrown away a perfectly good recording.
  static const double _maxNoiseFloor = -35.0;

  StreamSubscription<Amplitude>? _meter;
  Timer? _deadline;
  Completer<_TurnOutcome>? _turn;

  /// Live microphone level, 0..1, for the UI to show that it's hearing
  /// something. With a remote backend there are no partial words to display,
  /// so this is the only feedback the user gets.
  final StreamController<double> _levels = StreamController<double>.broadcast();
  Stream<double> get levels => _levels.stream;

  bool get isRecording => _turn != null && !_turn!.isCompleted;

  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// Records until the speaker stops, and returns the WAV path — or null if
  /// nothing was said, permission was refused, or [cancel] was called.
  ///
  /// 16 kHz mono WAV deliberately: it's what Whisper resamples to anyway, and
  /// every implementation accepts it without needing ffmpeg in the container.
  Future<String?> recordTurn() async {
    if (isRecording) return null;
    if (!await hasPermission()) return null;

    final directory = await _recordingsDirectory();
    final file = path.join(
      directory.path,
      'turn_${DateTime.now().microsecondsSinceEpoch}.wav',
    );

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          // Both help a phone held at arm's length; the recorder ignores them
          // where the platform doesn't offer them.
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: file,
      );
    } catch (_) {
      return null;
    }

    final turn = Completer<_TurnOutcome>();
    _turn = turn;

    var speechHeard = false;
    var silenceSince = DateTime.now();
    var calibrationSamples = <double>[];
    double? noiseFloor;
    final startedAt = DateTime.now();

    _deadline = Timer(_maxTurn, () {
      if (!turn.isCompleted) turn.complete(_TurnOutcome.ended);
    });

    _meter = _recorder.onAmplitudeChanged(_pollInterval).listen((amplitude) {
      // `current` is dBFS: 0 is clipping, about -60 is silence.
      final db = amplitude.current.isFinite ? amplitude.current : -60.0;
      _levels.add(((db + 50) / 50).clamp(0.0, 1.0));

      if (noiseFloor == null) {
        calibrationSamples.add(db);
        if (calibrationSamples.length < _calibrationFrames) return;
        // Quietest calibration frame, so a cough during calibration doesn't
        // raise the floor, then capped in case the whole window was speech.
        noiseFloor =
            math.min(calibrationSamples.reduce(math.min), _maxNoiseFloor);
        return;
      }

      // Keep tracking downward: a floor measured while someone was still
      // talking corrects itself the moment a genuinely quiet frame arrives.
      if (db < noiseFloor!) noiseFloor = db;

      final isSpeech = db > noiseFloor! + _speechMargin;

      if (isSpeech) {
        speechHeard = true;
        silenceSince = DateTime.now();
        return;
      }

      final now = DateTime.now();
      if (speechHeard) {
        if (now.difference(silenceSince) >= _endpointSilence) {
          if (!turn.isCompleted) turn.complete(_TurnOutcome.ended);
        }
      } else if (now.difference(startedAt) >= _noSpeechTimeout) {
        if (!turn.isCompleted) turn.complete(_TurnOutcome.silent);
      }
    }, onError: (_) {
      if (!turn.isCompleted) turn.complete(_TurnOutcome.ended);
    });

    final outcome = await turn.future;
    await _teardown();

    final recorded = await _stopRecorder();
    if (outcome != _TurnOutcome.ended || recorded == null) {
      await _discard(recorded);
      return null;
    }
    if (!speechHeard) {
      await _discard(recorded);
      return null;
    }
    return recorded;
  }

  /// Ends the turn now and keeps what was recorded — the user tapping "stop".
  void finish() {
    final turn = _turn;
    if (turn != null && !turn.isCompleted) turn.complete(_TurnOutcome.ended);
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

  Future<void> _teardown() async {
    await _meter?.cancel();
    _meter = null;
    _deadline?.cancel();
    _deadline = null;
    _turn = null;
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
