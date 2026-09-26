import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:horizon/Services/generation_keepalive.dart';
import 'package:horizon/Services/voice/stt/mic_pcm_stream.dart';
import 'package:horizon/Services/voice/wake/onnx_wake_word_models.dart';
import 'package:horizon/Services/voice/wake/wake_word_detector.dart';

/// Listens for "Hey Horizon" and opens Horizon Voice when it hears it.
///
/// Entirely on the phone: audio goes through the detector and nowhere else,
/// is never stored, and never leaves the device. Only after the phrase is
/// heard does Horizon Voice open and start a turn the ordinary way.
///
/// Runs only while it is wanted *and* allowed: [enabled] is the user's
/// setting, and [pause]/[resume] are how the rest of the app borrows the
/// microphone — Horizon Voice holds it for the whole conversation, and two
/// recorders on one microphone means one of them hears silence.
class WakeWordListener extends ChangeNotifier {
  WakeWordListener({required this.onWake});

  /// Called on the main isolate when the phrase is heard.
  final VoidCallback onWake;

  final MicPcmStream _mic = MicPcmStream(voiceIsolation: false);
  WakeWordDetector? _detector;
  OnnxWakeWordModels? _models;
  StreamSubscription<Float32List>? _frames;
  bool _loadFailed = false;

  /// Reopens the microphone if frames stop arriving. A capture that ends
  /// without an error — an audio-focus pause, a route change, another app
  /// grabbing the input — otherwise leaves the listener "running" and deaf,
  /// which from the outside is exactly "it worked once and then died".
  Timer? _watchdog;
  DateTime _lastFrame = DateTime.now();
  static const Duration _stallAfter = Duration(seconds: 3);

  bool _enabled = false;
  bool get enabled => _enabled;

  /// Frames the score must hold to count — see [WakeWordDetector.sustain].
  int _sustain = WakeWordDetector.balancedSustain;
  int get sustain => _sustain;
  set sustain(int value) {
    _sustain = value;
    _detector?.sustain = value;
    notifyListeners();
  }

  /// Reasons the listener is held off, by owner. A set rather than a flag so
  /// two owners overlapping — Horizon Voice open while the app backgrounds —
  /// can't resume it early by releasing one of them.
  final Set<String> _pausedBy = {};

  bool get isListening => _frames != null;

  /// What the bundled model listens for, once loaded. Null before then, or
  /// when no wake model is bundled.
  String? get phrase => _models?.phrase;

  /// Why it isn't listening when it should be, for the settings screen.
  String? get problem => _loadFailed
      ? 'The wake word model could not be loaded on this device.'
      : null;

  /// Whether listening carries on with the app in the background: true
  /// once the microphone foreground service is running. Without it Android
  /// cuts the microphone off the moment the app leaves the screen, so the
  /// listener pauses instead of pretending.
  bool get listensInBackground => _backgroundHeld;
  bool _backgroundHeld = false;

  /// Must be called while the app is on screen — Android only lets a
  /// microphone service start from the foreground.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    _backgroundHeld = await GenerationKeepalive.holdForWakeWord(value);
    await _sync();
  }

  /// The app came on screen: the one moment the background service can be
  /// (re)started, if it isn't already running.
  Future<void> appVisible() async {
    if (_enabled && !_backgroundHeld) {
      _backgroundHeld = await GenerationKeepalive.holdForWakeWord(true);
    }
    await resume('background');
  }

  /// The app left the screen. Keeps listening if the service is holding
  /// the microphone; otherwise lets it go.
  Future<void> appHidden() async {
    if (_enabled) _backgroundHeld = await GenerationKeepalive.holdsMicrophone();
    debugPrint('voice: app hidden — wake word '
        '${_enabled && _backgroundHeld ? 'keeps listening in the background' : 'pauses (no microphone service)'}');
    if (_enabled && _backgroundHeld) return;
    await pause('background');
  }

  Future<void> pause(String owner) async {
    _pausedBy.add(owner);
    await _sync();
  }

  Future<void> resume(String owner) async {
    _pausedBy.remove(owner);
    await _sync();
  }

  /// Every start and stop, one at a time. Overlapping syncs — a page
  /// resuming while the app comes back on screen, a watchdog restart during
  /// a resume — used to both pass the "not listening yet" check and each
  /// subscribe to the microphone, so every frame reached the detector twice
  /// and its scores never held the threshold again: the wake word that
  /// worked once.
  Future<void> _queue = Future.value();

  Future<void> _sync() {
    final next = _queue.then((_) => _syncNow()).catchError((Object e) {
      debugPrint('voice: wake word sync failed: $e');
    });
    _queue = next;
    return next;
  }

  bool get _wanted => _enabled && _pausedBy.isEmpty;

  Future<void> _syncNow() async {
    if (_enabled && !_wanted) debugPrint('voice: wake word held off by ${_pausedBy.join(', ')}');
    if (_wanted && !isListening) {
      await _start();
    } else if (!_wanted && isListening) {
      await _stop();
    }
    notifyListeners();
  }

  Future<void> _start() async {
    if (_loadFailed) return;
    _models ??= await OnnxWakeWordModels.load();
    final models = _models;
    if (models == null) {
      _loadFailed = true;
      debugPrint('voice: wake word model unavailable');
      return;
    }
    if (!_wanted) return;
    if (!await _mic.start()) {
      debugPrint('voice: wake word could not open the microphone; retrying');
      _scheduleRetry();
      return;
    }
    // Checked again now the microphone is open: a pause that arrived while
    // it was opening found nothing to stop, and would otherwise be ignored.
    if (!_wanted) {
      await _mic.stop();
      return;
    }
    final detector = _detector ??= WakeWordDetector(models, sustain: _sustain)
      ..onNearMiss = (peak, run) => debugPrint(
          'voice: wake near-miss — peak ${peak.toStringAsFixed(2)}, '
          '$run frame${run == 1 ? '' : 's'} over the line (needs $_sustain)');
    detector.reset();
    _lastFrame = DateTime.now();
    _lastSound = DateTime.now();
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) => _checkStall());
    _frames = _mic.frames.listen((frame) {
      _lastFrame = DateTime.now();
      if (frame.any((sample) => sample != 0)) _lastSound = _lastFrame;
      if (!detector.add(frame)) return;
      debugPrint('voice: wake word heard (score '
          '${detector.lastScore.toStringAsFixed(2)})');
      unawaited(HapticFeedback.mediumImpact());
      onWake();
    });
    debugPrint('voice: wake word listening for "${models.phrase}"');
  }

  /// Last frame that wasn't pure digital silence. A real microphone always
  /// has some noise on it; exact zeros mean the capture has been silenced —
  /// by another recorder or the audio policy — while frames keep arriving.
  DateTime _lastSound = DateTime.now();
  static const Duration _silencedAfter = Duration(seconds: 5);

  Timer? _retry;

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), () {
      if (_wanted && !isListening) unawaited(_sync());
    });
  }

  Future<void> _checkStall() async {
    if (!isListening) return;
    final now = DateTime.now();
    final stalled = now.difference(_lastFrame) >= _stallAfter;
    final silenced = now.difference(_lastSound) >= _silencedAfter;
    if (!stalled && !silenced) return;
    debugPrint('voice: wake word microphone ${stalled ? 'stopped delivering' : 'went silent'}; reopening it');
    _queue = _queue.then((_) async {
      await _stop();
      await _syncNow();
    });
    await _queue;
  }

  Future<void> _stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    _retry?.cancel();
    await _frames?.cancel();
    _frames = null;
    await _mic.stop();
  }

  @override
  void dispose() {
    unawaited(_stop());
    unawaited(_mic.dispose());
    _models?.dispose();
    super.dispose();
  }
}
