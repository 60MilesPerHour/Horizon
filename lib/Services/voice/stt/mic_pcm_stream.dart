import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

/// The microphone as a live stream rather than a file.
///
/// The file-based path ([VoiceRecorder]) records a whole turn, stops, and
/// uploads it — which is why transcription can only ever begin after the
/// speaker has finished. Streaming transcription needs the opposite shape:
/// frames handed over while they are still being spoken. This class is that
/// shape, and nothing more. It does not decide when a turn ended (that stays
/// with [TurnEndpointer]) and it does not know what the audio is for.
///
/// Two outputs from the one capture:
///  - [frames], 16 kHz mono float32 in [-1, 1], which is what every
///    streaming ASR server wants on the wire;
///  - [levelsDb], one RMS level per frame, which feeds the endpointer and the
///    on-screen meter.
///
/// RMS rather than the peak that `record`'s own amplitude stream reports on
/// Android: peak is what a single sample did, so one keyboard click reads as
/// speech. The endpointer's thresholds are all *relative to a rolling noise
/// floor*, so the constant offset between the two measures comes out in the
/// wash — but anything comparing against an absolute dBFS figure has to be
/// told which one it is looking at, because RMS speech sits some 8-10 dB
/// below its own peaks. Hence [speechRmsDb].
class MicPcmStream {
  /// [voiceIsolation] picks the call audio path, with the phone's own noise
  /// removal and echo cancellation — right for a conversation. It also puts
  /// the whole device into "in call" audio mode while open, which is wrong
  /// for anything that listens for long stretches, like the wake word.
  MicPcmStream({this.voiceIsolation = true});

  final bool voiceIsolation;

  /// What Whisper resamples to anyway, and the rate every streaming server
  /// in this space expects.
  static const int sampleRate = 16000;

  /// Ordinary speech, measured as RMS at arm's length. The file path's
  /// equivalent figure is about -12 dBFS because it is measuring peaks.
  static const double speechRmsDb = -26.0;

  /// Reported for a frame with no signal at all. Real silence is around
  /// -90 dBFS and the log of an all-zero frame is negative infinity, which
  /// poisons every average downstream of it.
  static const double silenceDb = -70.0;

  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _bytes;

  final StreamController<Float32List> _frames =
      StreamController<Float32List>.broadcast();
  final StreamController<double> _levels = StreamController<double>.broadcast();

  /// 16 kHz mono float32 frames, in capture order.
  Stream<Float32List> get frames => _frames.stream;

  /// One RMS level in dBFS per frame delivered.
  Stream<double> get levelsDb => _levels.stream;

  bool _running = false;
  bool get isRunning => _running;

  /// Total audio delivered so far, for deciding how long a turn has run
  /// without trusting wall-clock time on a device that may have been paused.
  Duration get captured => Duration(
        microseconds: _samples * Duration.microsecondsPerSecond ~/ sampleRate,
      );
  int _samples = 0;

  /// Remembered once granted. record answers its permission check through
  /// the activity, and with no activity — Horizon swiped out of recents, the
  /// wake word still running in the background — it answers "no" without
  /// looking, which kept the wake word's microphone from ever reopening.
  /// Android enforces the real permission when capture starts regardless, so
  /// a revoked permission still fails, just one step later.
  static bool _granted = false;

  Future<bool> hasPermission() async {
    if (_granted) return true;
    try {
      _granted = await (_recorder ??= AudioRecorder()).hasPermission();
      return _granted;
    } catch (_) {
      return false;
    }
  }

  /// Opens the microphone. Returns false if it could not be opened at all —
  /// no permission, or a platform whose `record` implementation has no
  /// streaming support, which is the case that has to fall back to the
  /// file-based path rather than leave voice mode broken.
  Future<bool> start() async {
    if (_running) return true;
    final recorder = _recorder ??= AudioRecorder();
    if (!await hasPermission()) return false;

    _samples = 0;
    try {
      final stream = await recorder.startStream(_config);
      _bytes = stream.listen(_onBytes, onError: (_) => stop(), cancelOnError: true);
    } catch (e) {
      debugPrint('voice: microphone failed to open: $e');
      return false;
    }
    _running = true;
    return true;
  }

  Future<void> stop() async {
    if (!_running && _bytes == null) return;
    _running = false;
    await _bytes?.cancel();
    _bytes = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _recorder?.dispose();
    } catch (_) {}
    _recorder = null;
    if (!_frames.isClosed) await _frames.close();
    if (!_levels.isClosed) await _levels.close();
  }

  /// `autoGain` off because Android's AGC lifts room noise in the gaps
  /// between words and flattens exactly the contrast the endpointer reads.
  ///
  /// The voice-communication source rather than voice-recognition, unlike
  /// [VoiceRecorder]. Voice-recognition is specified as lightly processed, so
  /// the room arrives almost untouched; voice-communication is the call
  /// path, where the phone's own multi-mic voice isolation and echo
  /// canceller run. That is the one place background noise can be removed
  /// *before* anything else hears it, and the echo canceller is what lets
  /// the mic stay open while the assistant talks without hearing itself.
  /// Whisper doesn't mind the processing; it was measured transcribing
  /// babble louder than the voice.
  RecordConfig get _config => voiceIsolation ? _conversation : _listening;

  static const RecordConfig _listening = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
        // record's default pauses capture whenever anything else takes audio
        // focus — a spoken reply, a notification sound, music — and a
        // permanent loss leaves it paused for good. That is how the wake word
        // "died": still running, hearing nothing. It only listens, so there
        // is nothing to yield.
        audioInterruption: AudioInterruptionMode.none,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceRecognition,
        ),
      );

  static const RecordConfig _conversation = RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: false,
        echoCancel: true,
        noiseSuppress: true,
        // No audio-focus request. With record's default, opening this mic
        // takes focus, and the talk-over watcher opens it while a reply is
        // playing — which paused the reply's own audio. The session has its
        // own watchdog for a microphone that goes quiet.
        audioInterruption: AudioInterruptionMode.none,
        androidConfig: AndroidRecordConfig(
          audioSource: AndroidAudioSource.voiceCommunication,
          // The call path routes audio like a call, including to the
          // earpiece; keep playback on the speaker.
          speakerphone: true,
          audioManagerMode: AudioManagerMode.modeInCommunication,
        ),
      );

  void _onBytes(Uint8List bytes) {
    if (_frames.isClosed || bytes.isEmpty) return;
    final frame = toFloat32(bytes);
    if (frame.isEmpty) return;
    _samples += frame.length;
    _frames.add(frame);
    if (!_levels.isClosed) _levels.add(rmsDb(frame));
  }

  /// Little-endian signed 16-bit PCM to float32 in [-1, 1].
  ///
  /// An odd trailing byte is dropped rather than padded: it is half a sample
  /// at a frame boundary and the next frame carries its other half, so
  /// inventing a zero for it puts a click in the audio every frame.
  static Float32List toFloat32(Uint8List bytes) {
    final samples = bytes.length ~/ 2;
    final view = ByteData.sublistView(bytes, 0, samples * 2);
    final out = Float32List(samples);
    for (var i = 0; i < samples; i++) {
      out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// RMS of a frame in dBFS, floored at [silenceDb].
  static double rmsDb(Float32List frame) {
    if (frame.isEmpty) return silenceDb;
    var sum = 0.0;
    for (final sample in frame) {
      sum += sample * sample;
    }
    final rms = math.sqrt(sum / frame.length);
    if (rms <= 0) return silenceDb;
    final db = 20 * math.log(rms) / math.ln10;
    return db < silenceDb ? silenceDb : (db > 0 ? 0 : db);
  }

  /// Float32 frames as a 16-bit PCM WAV file, for handing a captured turn to
  /// the non-streaming `/v1/audio/transcriptions` endpoint — the accuracy
  /// backstop when the streaming server drops mid-turn.
  static Uint8List toWav(List<Float32List> frames, {int rate = sampleRate}) {
    final total = frames.fold<int>(0, (sum, f) => sum + f.length);
    final bytes = BytesBuilder();
    final header = ByteData(44);
    void ascii(int offset, String tag) {
      for (var i = 0; i < tag.length; i++) {
        header.setUint8(offset + i, tag.codeUnitAt(i));
      }
    }

    final dataBytes = total * 2;
    ascii(0, 'RIFF');
    header.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // mono
    header.setUint32(24, rate, Endian.little);
    header.setUint32(28, rate * 2, Endian.little); // byte rate
    header.setUint16(32, 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits
    ascii(36, 'data');
    header.setUint32(40, dataBytes, Endian.little);
    bytes.add(header.buffer.asUint8List());

    final pcm = ByteData(dataBytes);
    var i = 0;
    for (final frame in frames) {
      for (final sample in frame) {
        final clamped = sample < -1.0 ? -1.0 : (sample > 1.0 ? 1.0 : sample);
        pcm.setInt16(i, (clamped * 32767).round(), Endian.little);
        i += 2;
      }
    }
    bytes.add(pcm.buffer.asUint8List());
    return bytes.toBytes();
  }
}
