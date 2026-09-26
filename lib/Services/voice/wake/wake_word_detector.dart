import 'dart:typed_data';

/// The three networks behind an openWakeWord detector.
///
/// Split out from [WakeWordDetector] so the streaming logic — which is where
/// the bugs live — can be driven in a test with fakes, and so the runtime
/// (ONNX today) is one class to swap rather than a rewrite.
abstract class WakeWordModels {
  /// Mel spectrogram of [samples] (int16-scale floats, 16 kHz), as frames of
  /// 32 values, flattened. Already transformed the way openWakeWord's own
  /// front end does (`x / 10 + 2`).
  Float32List melspectrogram(Float32List samples);

  /// One 96-value speech embedding from 76 mel frames (76 × 32, flattened).
  Float32List embed(Float32List mel);

  /// Probability, 0..1, that the last 16 embeddings (16 × 96, flattened)
  /// end in the wake phrase.
  double score(Float32List embeddings);

  void dispose();
}

/// Streams microphone audio through an openWakeWord model and says when the
/// wake phrase was heard.
///
/// The pipeline, per 80 ms of audio:
///  - a mel spectrogram over that chunk plus 30 ms of context;
///  - one embedding over the latest 76 mel frames (~0.8 s);
///  - one score over the latest 16 embeddings (~1.3 s), which is how long a
///    two-word phrase takes to say.
///
/// Mirrors openWakeWord's streaming preprocessor step for step, and was
/// checked against it: the same audio gives the same scores.
class WakeWordDetector {
  WakeWordDetector(this.models, {this.threshold = 0.5, this.sustain = balancedSustain});

  final WakeWordModels models;

  /// Score at which the phrase counts as said. openWakeWord's default, and
  /// measured here: the phrase scored 0.98, "Hey, what time is it?" 0.001.
  final double threshold;

  static const int chunk = 1280; // 80 ms at 16 kHz
  static const int _context = 480; // 3 hops of 160 samples
  static const int _melFrames = 76;
  static const int _melBins = 32;
  static const int _embeddings = 16;
  static const int _embeddingSize = 96;

  /// Scores ignored after a (re)start: the buffers still hold the padding
  /// they were initialised with, and openWakeWord discards the first five
  /// for the same reason.
  static const int _warmup = 5;

  /// Consecutive 80 ms scores that must clear [threshold] before it counts.
  ///
  /// The phrase and its near-misses can peak equally high — "the horizon
  /// looks beautiful" scored 0.97 against the real phrase's 0.97 — but they
  /// don't stay there. Measured on the trained model: "Hey Horizon" held the
  /// threshold for 7 frames in every voice tested; "Horizon" alone, "Hey
  /// Harrison" and "the horizon…" for 4 at most. Five sits between, for
  /// about 0.3 s of extra latency. For an app whose name is an ordinary
  /// word, that's the difference between waking on its name and waking on
  /// conversation.
  ///
  /// Settable, and lowered by default after real use: a real "Hey Horizon"
  /// peaked at 0.94 but held the line for 3 frames — a person says it
  /// faster than the synthetic voices it was trained on. [strictSustain]
  /// keeps the original bar for anyone bothered by false wakes.
  int sustain;

  static const int balancedSustain = 3;
  static const int strictSustain = 5;

  /// Quiet period after a detection, so one "Hey Horizon" is one wake and
  /// not three consecutive frames over the threshold.
  static const int _refractoryChunks = 25; // 2 s

  final List<double> _pending = [];
  final List<double> _raw = [];
  final List<Float32List> _mel = [];
  final List<Float32List> _features = [];
  int _scored = 0;
  int _cooldown = 0;
  int _above = 0;

  /// Most recent score, for a settings meter or diagnostics.
  double lastScore = 0;

  /// Called when a burst of wake-like audio ends without waking: its peak
  /// score and how many frames in a row cleared the threshold. What tuning
  /// needs to know — how close the misses come, and on which of the two
  /// tests they fail.
  void Function(double peak, int run)? onNearMiss;
  double _burstPeak = 0;
  int _burstRun = 0;
  int _burstBest = 0;

  void reset() {
    _pending.clear();
    _raw.clear();
    _mel
      ..clear()
      ..addAll(List.generate(_melFrames, (_) => Float32List(_melBins)..fillRange(0, _melBins, 1)));
    _features.clear();
    _scored = 0;
    _cooldown = 0;
    _above = 0;
    lastScore = 0;
  }

  /// Feeds microphone audio as floats in [-1, 1], any length. Returns true
  /// when this audio completed the wake phrase.
  bool add(Float32List audio) {
    if (_mel.isEmpty) reset();
    for (final sample in audio) {
      _pending.add(sample * 32767.0);
    }
    var woke = false;
    while (_pending.length >= chunk) {
      final next = _pending.sublist(0, chunk);
      _pending.removeRange(0, chunk);
      if (_step(next)) woke = true;
    }
    return woke;
  }

  bool _step(List<double> samples) {
    _raw.addAll(samples);
    if (_raw.length > chunk + _context) {
      _raw.removeRange(0, _raw.length - (chunk + _context));
    }

    final spec = models.melspectrogram(Float32List.fromList(_raw));
    for (var i = 0; i + _melBins <= spec.length; i += _melBins) {
      _mel.add(Float32List.sublistView(spec, i, i + _melBins));
    }
    if (_mel.length > _melFrames) _mel.removeRange(0, _mel.length - _melFrames);

    final window = Float32List(_melFrames * _melBins);
    for (var f = 0; f < _melFrames; f++) {
      window.setAll(f * _melBins, _mel[f]);
    }
    _features.add(models.embed(window));
    if (_features.length > _embeddings) {
      _features.removeRange(0, _features.length - _embeddings);
    }
    if (_features.length < _embeddings) return false;

    final input = Float32List(_embeddings * _embeddingSize);
    for (var e = 0; e < _embeddings; e++) {
      input.setAll(e * _embeddingSize, _features[e]);
    }
    lastScore = models.score(input);
    _scored++;

    if (_cooldown > 0) {
      _cooldown--;
      return false;
    }
    if (_scored <= _warmup) return false;
    if (lastScore >= 0.15) {
      _burstPeak = lastScore > _burstPeak ? lastScore : _burstPeak;
      _burstRun = lastScore >= threshold ? _burstRun + 1 : 0;
      if (_burstRun > _burstBest) _burstBest = _burstRun;
    } else if (_burstPeak > 0) {
      onNearMiss?.call(_burstPeak, _burstBest);
      _burstPeak = 0;
      _burstRun = 0;
      _burstBest = 0;
    }
    _above = lastScore >= threshold ? _above + 1 : 0;
    if (_above < sustain) return false;
    _above = 0;
    _burstPeak = 0;
    _burstRun = 0;
    _burstBest = 0;
    _cooldown = _refractoryChunks;
    return true;
  }
}
