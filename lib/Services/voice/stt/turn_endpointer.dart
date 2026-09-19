/// What the endpointer wants the recorder to do after the latest frame.
enum TurnSignal {
  /// Keep recording.
  listening,

  /// The speaker finished. Keep the audio.
  ended,

  /// Nothing worth transcribing was said. Throw the audio away.
  silent,
}

/// Decides when a spoken turn has ended, from the microphone's level meter.
///
/// Remote transcription needs a finished clip, so endpointing is ours rather
/// than the recogniser's. This is deliberately pure — it takes dBFS frames and
/// returns a decision — because the interesting behaviour is what it does in a
/// noisy room, and that has to be testable without a microphone.
///
/// ## Why the previous energy gate failed away from home
///
/// It measured a noise floor over the first four frames, capped it at
/// -35 dBFS, and thereafter only ever tracked *downward*. Both failure modes
/// are what "voice is dogshit outside" actually means:
///
///  - **A room that gets louder.** The floor could not rise, so once the
///    ambience passed floor + margin every single frame read as speech, the
///    turn never ended, and it ran to the hard cap. Measured against street
///    and café-grade noise, ambience sits at -34 to -24 dBFS — at or above
///    that -35 cap, i.e. exactly where it breaks.
///  - **A margin wider than the actual SNR.** It wanted 9 dB over the floor.
///    Real speech-to-ambience separation in those recordings is 3-10 dB, so
///    speech often never latched at all and a good recording was discarded on
///    the no-speech timeout.
///
/// So: the floor is a low percentile of a sliding window, which adapts in
/// both directions and self-heals when the opening frames are all speech;
/// speech must be *sustained*, not loud for one frame; ending a turn uses
/// hysteresis, plus a look at how much of the recent past was back down at
/// the room; and a level that never falls back to the room at all ends the
/// turn in seconds rather than holding the microphone open for a minute.
///
/// Its limits, measured rather than assumed: it hears speech down to about
/// 5 dB SNR and rejects pure babble noise. Below that, tapping stop is the
/// way through — see [finishNow] — because transcription handles audio that
/// level metering cannot.
class TurnEndpointer {
  TurnEndpointer({this.frame = const Duration(milliseconds: 100)});

  /// Nominal length of one level sample: what the recorder asks the meter
  /// for, and the assumed step when [add] isn't told the real one.
  final Duration frame;

  /// How much history the room measurement covers. Five seconds: long enough
  /// that it isn't skewed by one loud moment, short enough that a louder room
  /// is reflected while you're still in the same sentence. Inside any five
  /// seconds of ordinary speech there is a gap between words that reaches the
  /// ambience.
  ///
  /// A span rather than a frame count, like everything else in here: the
  /// meters deliver on their own schedule, and on a loaded phone frames
  /// arrive every 200-300 ms rather than the 100 ms asked for. Counted in
  /// frames, that quietly turns every threshold in this class into two or
  /// three times what it says.
  static const Duration _windowSpan = Duration(seconds: 5);

  /// Which point in the sorted window is taken as the room.
  ///
  /// Not the minimum: Android's meter reports the *peak* of each frame, and
  /// measured babble noise swings about 7 dB frame to frame, so its minimum
  /// sits well under the level the same noise spends most of its time at. A
  /// floor that low puts the speech threshold inside the noise's own
  /// variance, which is how a recording of a busy room gets uploaded as a
  /// spoken turn. The low fifth of the window is the room; the rest may not
  /// be.
  static const double _floorPercentile = 0.2;

  /// People talk the instant they tap the microphone, so the opening window
  /// can be all speech and the floor starts out too high to latch anything.
  ///
  /// The old gate handled that by capping the floor at -35 dBFS, which is
  /// what makes it fail outdoors: a room louder than the cap clears the
  /// speech threshold on the first frame, so ambience latches as a spoken
  /// turn and the floor never learns otherwise. There is no threshold that
  /// tells "loud room" from "quiet room plus speech" in 300 ms.
  ///
  /// So instead: wait, and judge it on something the floor can't spoil.
  ///
  /// Audio is being recorded from the moment the button is tapped either way,
  /// so a late latch loses nothing — the words are in the clip regardless.
  /// After this long, enough audio standing well above the quietest thing
  /// heard *recently* is taken as speech that started before the room could
  /// be measured, and the turn latches retroactively.
  ///
  /// Deliberately measured against the raw recent minimum rather than the
  /// floor: when the opening frames are all speech the floor sits at speaking
  /// volume, so anything derived from it — including the ordinary attack
  /// threshold — can never be crossed, which is the whole failure this exists
  /// to catch.
  static const Duration _retroLatchAfter = Duration(milliseconds: 1200);

  /// Speech-level audio needed to latch retroactively.
  static const Duration _retroLatchSpeech = Duration(milliseconds: 400);

  /// Bounds on the floor estimate — wide on purpose.
  ///
  /// A ceiling anywhere near ordinary speaking level is the same mistake as
  /// the old -35 dBFS cap: in a recording where the room itself peaks at
  /// -14 dBFS, a floor clamped to -18 puts the room above the release
  /// threshold permanently, so the turn is "still talking" until the hard cap
  /// no matter how long you stay quiet. The room is whatever the room is.
  static const double _floorMin = -65.0;
  static const double _floorMax = -6.0;

  /// dB over the floor that counts as speech starting.
  ///
  /// Checked against traces taken from real recordings rather than picked: on
  /// a peak meter, speech at 5-10 dB RMS SNR still stands about 10 dB over
  /// the ambience, because a voice has a higher crest factor than a room
  /// does. 7 dB clears that while leaving babble noise — which was latching
  /// as a spoken turn at 5 dB — below the line.
  static const double _attackMargin = 7.0;

  /// dB over the floor that counts as *still* talking. Lower than the attack
  /// so a trailing syllable doesn't end the turn (hysteresis).
  ///
  /// Measured against the room and nothing else. An earlier version also
  /// ended the turn when the level fell more than 9 dB below the loudest
  /// syllable heard, meaning to catch the end of a sentence in a room too
  /// loud for the floor to help. On a peak meter that is inside the ordinary
  /// range of one sentence: "…and remind me tomorrow, please" sits 15 dB
  /// under the emphasis earlier in the same breath, so it ended the turn
  /// over the top of the quiet half of what was being said. The loud-room
  /// case is answered by [_mostlyQuiet] instead, which asks the same question
  /// without a threshold that moves with the speaker's volume.
  static const double _releaseMargin = 3.5;

  /// Unbroken time over the attack threshold before speech is believed.
  /// Noise fluctuation doesn't sustain that; a syllable does. Replaces
  /// trusting a single frame, which let a door slam open a turn and upload a
  /// clip of nothing for Whisper to hallucinate over.
  static const Duration _attackTime = Duration(milliseconds: 300);

  /// Silence that ends the turn once speech has been heard. Survives the
  /// pause in "the answer is… four" without adding dead air to every reply.
  static const Duration hangover = Duration(milliseconds: 750);

  /// Give up if nobody says anything at all.
  static const Duration noSpeechTimeout = Duration(seconds: 8);

  /// Total speech needed for the turn to be worth uploading, so a sound that
  /// only just qualified as speech isn't uploaded on its own.
  ///
  /// Reachable by a single short word only because latching credits the frame
  /// the median smoothing swallowed — see [_latch]. Without that, "no" and
  /// "stop" measured 300 ms here, fell under this line, and were thrown away
  /// before transcription while the microphone quietly reopened.
  static const Duration minimumSpeech = Duration(milliseconds: 400);

  /// Continuous above-release level after which the floor may start taking
  /// every frame again, speech or not.
  ///
  /// The floor is normally measured from non-speech frames only, or a long
  /// sentence would drag it up into your own voice and cut you off
  /// mid-sentence. But if *nothing* has dipped to the room for this long, the
  /// premise may be wrong: the level could be the room, having got louder.
  static const Duration _floorUnfreezeAfter = Duration(seconds: 4);

  /// Level spread, in dB, below which a sustained level is taken for the room
  /// rather than a long sentence.
  ///
  /// This is the difference between the two, and time alone cannot tell them
  /// apart: a voice swings 8-15 dB from syllable to syllable, while a fan, a
  /// road or a crowd holds within a couple of dB. Without this check,
  /// unfreezing on duration alone walked the floor up into the speaker's own
  /// voice and truncated ordinary dictation at nine seconds.
  static const double _steadyLevelSpread = 5.0;

  /// How much recent history the spread is measured over.
  static const Duration _spreadSpan = Duration(seconds: 2);

  /// History needed before the quiet-fraction check will call a turn over.
  static const Duration _dutySpan = Duration(milliseconds: 1500);

  /// Fraction of that history below the release threshold that ends a turn
  /// no run of consecutive quiet ever would.
  ///
  /// Clear of what a speaker does: measured on real traces, a voice spends
  /// 20-50% of a sentence under that line between syllables, and as much as
  /// two thirds of it when the room is nearly as loud as the voice. Four
  /// fifths still catches a turn that has actually ended, because then it is
  /// essentially all of it.
  static const double _quietFraction = 0.8;

  /// Continuous above-release level that is treated as the room, not you.
  ///
  /// Nobody talks for this long without dipping to the floor between words,
  /// so this is the guard against the runaway that the old gate hit: end the
  /// turn and transcribe what we have, rather than holding the microphone
  /// open to the hard cap while the user waits.
  static const Duration maxContinuousSpeech = Duration(seconds: 15);

  /// Hard cap on one turn, so a stuck-open microphone can't record forever
  /// and then upload it.
  static const Duration maxTurn = Duration(seconds: 60);

  /// Room measurement: level plus when it was heard, so the span is real
  /// time rather than a number of frames.
  final List<_Sample> _window = <_Sample>[];

  /// Every recent frame, raw and speech included — the window can't answer
  /// "how much is this level moving about", because it deliberately excludes
  /// speech and holds smoothed values.
  final List<_Sample> _spread = <_Sample>[];

  final List<double> _recent = <double>[];

  Duration _aboveTime = Duration.zero;
  Duration _loudTime = Duration.zero;
  /// Starts at the ceiling: until a frame has been measured, nothing is
  /// loud enough to be speech.
  double _floor = _floorMax;
  double _level = 0.0;

  Duration _elapsed = Duration.zero;
  Duration _speech = Duration.zero;
  Duration _silence = Duration.zero;
  Duration _continuous = Duration.zero;

  bool _latched = false;
  bool _ranAway = false;

  /// When speech was first heard, so the quiet-fraction check can be told to
  /// ignore history from before that.
  Duration _latchedAt = Duration.zero;

  /// True once sustained speech has been heard.
  bool get speechHeard => _latched;

  /// How much of the turn was speech. Used to reject clips that are all room.
  Duration get speechDuration => _speech;

  /// Current estimate of the room, in dBFS. Exposed for diagnostics.
  double get noiseFloorDb => _floor;

  /// Whether the turn had to be ended by judgement rather than by hearing
  /// the speaker stop — somewhere loud enough that the level never properly
  /// came back down. Set only by the paths that actually end a turn, so it
  /// can be shown to the user as the reason.
  bool get endedOnNoise => _ranAway;

  /// Microphone level 0..1 for the UI, measured *against the room* rather
  /// than an absolute scale, so the meter tracks your voice and not the fan.
  double get level => _level;

  /// Feeds one level sample and returns what to do next.
  ///
  /// [delta] is the real time since the previous sample. Worth passing: the
  /// platform meters deliver on their own schedule and a slower cadence than
  /// requested would otherwise stretch every timeout here silently — a 750 ms
  /// hangover that is really 1.5 s reads as "it takes a while to realise I'm
  /// done", which is the bug this class exists to fix. Tests drive it at the
  /// nominal rate and leave it out.
  TurnSignal add(double rawDb, {Duration? delta}) {
    final step = delta ?? frame;
    // record_linux idles at -160 dB and a non-finite value shows up on some
    // platforms when the meter isn't ready yet.
    final db = (rawDb.isFinite ? rawDb : -80.0).clamp(-80.0, 0.0);

    // Median of three. Android reports the frame *peak*, not RMS, so a single
    // click is 10 dB above its neighbours; without this it reads as a
    // syllable and, worse, resets the silence timer.
    _recent.add(db);
    if (_recent.length > 3) _recent.removeAt(0);
    final smoothed = _median(_recent);

    _elapsed += step;

    // The *raw* level here, not the smoothed one. Median-of-three exists to
    // stop a single frame moving a threshold, and it does that by erasing
    // exactly the frame-to-frame swing this measures: run it through the
    // median and two-frame syllables flatten into a level as steady as a
    // fan, which then reads as the room and truncates the sentence.
    _spread.add(_Sample(db, _elapsed));
    _prune(_spread, _spreadSpan);

    // The room is measured from frames that aren't speech — otherwise a long
    // sentence walks the floor up into your own voice and the turn ends
    // mid-word.
    //
    // Before speech has latched every frame goes in regardless: at that point
    // there's nothing to protect, and skipping frames that merely *might* be
    // speech is how a busy room gets measured as a quiet one — the estimate
    // never moves off its starting value, the room itself clears the
    // threshold, and ambience latches as a spoken turn.
    final looksLikeSpeech = _latched && smoothed >= _floor + _releaseMargin;

    // A level that has stayed up for [_floorUnfreezeAfter] *and* is barely
    // moving is the room, not a sentence, so let it back into the
    // measurement. Both conditions matter: duration alone truncates ordinary
    // dictation, and spread alone would unfreeze during a monotone word.
    final steadyRoom = _continuous >= _floorUnfreezeAfter &&
        _levelSpread() < _steadyLevelSpread;

    if (!looksLikeSpeech || steadyRoom) {
      _window.add(_Sample(smoothed, _elapsed));
      _prune(_window, _windowSpan);
    }

    _floor = _measureFloor();
    final attack = _floor + _attackMargin;
    final release = _floor + _releaseMargin;
    // Deliberately the raw value, not the smoothed one: the meter should move
    // the instant the microphone hears something, even if the endpointer is
    // still deciding whether it was a syllable or a click.
    _level = ((db - _floor) / 24.0).clamp(0.0, 1.0);

    if (!_latched) {
      if (smoothed >= attack) {
        _aboveTime += step;
      } else {
        _aboveTime = Duration.zero;
      }

      // Second, independent detector for the same question, measured off the
      // raw signal's own recent range instead of the floor.
      if (db >= _recentQuietest() + _attackMargin) _loudTime += step;

      if (_aboveTime >= _attackTime) {
        _latch(_aboveTime, step);
      } else if (_elapsed >= _retroLatchAfter &&
          _loudTime >= _retroLatchSpeech) {
        // Someone who was already talking when the microphone opened.
        _latch(_loudTime, step);
      }

      if (_latched) {
        // Those frames are now known to be speech, so they have no business
        // in the room measurement. This is what makes talking over the start
        // of the turn work: with nothing but speech in the window it empties,
        // and the first gap between words measures the room properly.
        _window.removeWhere((sample) => sample.db >= attack);
        _floor = _measureFloor();
        return _capped();
      }

      if (_elapsed >= noSpeechTimeout) return TurnSignal.silent;
      return _capped();
    }

    if (smoothed >= release) {
      _speech += step;
      _continuous += step;

      // [hangover] is *consecutive* quiet, so any speech clears it. Anything
      // cleverer here — a counter that leaked back slowly — made the delay
      // after a sentence depend on how much someone had paused earlier in
      // it, which is both unpredictable and occasionally a cut-off.
      _silence = Duration.zero;

      if (_continuous >= maxContinuousSpeech) {
        _ranAway = true;
        return _finish();
      }
    } else {
      _silence += step;
      _continuous = Duration.zero;
      if (_silence >= hangover) return _finish();
    }

    // The flicker case, which consecutive quiet cannot see: when the room is
    // about as loud as the speaker, the level crosses the threshold every
    // other frame, so the hangover keeps resetting and the level never runs
    // continuously either. Nothing ends the turn and it sits open. Judging
    // the last couple of seconds as a whole catches it — someone still
    // talking does not spend most of that time below the line.
    if (_mostlyQuiet(release)) {
      _ranAway = true;
      return _finish();
    }

    return _capped();
  }

  /// Whether what has been captured so far is worth sending, on the strict
  /// terms the automatic path uses. For a turn that ends for a reason of its
  /// own — a dead meter, a lost audio session — rather than because the
  /// speaker stopped or asked it to.
  bool get worthUploading => _latched && _speech >= minimumSpeech;

  /// The user tapped stop: report whether what we captured is worth sending.
  ///
  /// More willing to keep the audio than the automatic path is. Somewhere too
  /// loud for the level meter to tell speech from the room, tapping stop is
  /// exactly what you do — and transcription copes with audio that
  /// endpointing can't (a 0 dB SNR clip of babble came back verbatim), so
  /// anything of a plausible length gets uploaded rather than discarded.
  TurnSignal finishNow() {
    if (_latched && _speech >= minimumSpeech) return TurnSignal.ended;
    if (_elapsed >= _minimumManualTurn) return TurnSignal.ended;
    return TurnSignal.silent;
  }

  /// Recording length below which a manual stop is treated as a mis-tap
  /// rather than a turn.
  static const Duration _minimumManualTurn = Duration(seconds: 1);

  /// Marks the turn as speech, crediting [heard] of it.
  ///
  /// Plus one frame, because the median of three swallows the onset: the
  /// frame where a word actually begins still reports the level before it.
  /// That missing frame is the difference between a brisk "no" counting as
  /// 300 ms — under [minimumSpeech], so discarded unheard — and counting as
  /// the 400 ms it really was.
  void _latch(Duration heard, Duration step) {
    _latched = true;
    _latchedAt = _elapsed;
    final credited = heard + step;
    _speech += credited;
    _continuous += credited;
  }

  /// Whether the recent past was mostly back down at the room — the turn is
  /// over even though no single stretch of quiet was long enough to say so.
  ///
  bool _mostlyQuiet(double roomLine) {
    if (_spread.isEmpty) return false;
    // Only history from after speech was heard. The room tone recorded
    // before the first word is genuinely quiet, and counting it declares the
    // turn over a second and a half into the first sentence.
    if (_spread.first.at < _latchedAt) return false;
    if (_elapsed - _spread.first.at < _dutySpan) return false;
    final quiet = _spread.where((sample) => sample.db < roomLine).length;
    return quiet / _spread.length >= _quietFraction;
  }

  /// The quietest raw level heard recently. Recent rather than for the whole
  /// turn, because a room that has got louder should raise it — otherwise
  /// ambience keeps clearing a threshold set against a quiet that is gone.
  double _recentQuietest() {
    var low = double.infinity;
    for (final sample in _spread) {
      if (sample.db < low) low = sample.db;
    }
    return low.isFinite ? low : 0;
  }

  /// How much the level has moved about recently, in dB. Speech swings;
  /// rooms don't.
  double _levelSpread() {
    if (_spread.length < 3) return 0;
    var low = double.infinity;
    var high = -double.infinity;
    for (final sample in _spread) {
      if (sample.db < low) low = sample.db;
      if (sample.db > high) high = sample.db;
    }
    return high - low;
  }

  void _prune(List<_Sample> samples, Duration span) {
    while (samples.isNotEmpty && _elapsed - samples.first.at > span) {
      samples.removeAt(0);
    }
  }

  TurnSignal _capped() {
    if (_elapsed >= maxTurn) return _finish();
    return TurnSignal.listening;
  }

  TurnSignal _finish() {
    if (!_latched || _speech < minimumSpeech) return TurnSignal.silent;
    return TurnSignal.ended;
  }

  double _measureFloor() {
    // An empty window means every frame so far has been speech, so there is
    // nothing to say about the room yet: hold the previous estimate.
    if (_window.isEmpty) return _floor;
    final sorted = _window.map((sample) => sample.db).toList()..sort();
    final index = (sorted.length * _floorPercentile).floor();
    return sorted[index.clamp(0, sorted.length - 1)]
        .clamp(_floorMin, _floorMax);
  }

  static double _median(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    return sorted[sorted.length ~/ 2];
  }
}

/// One level reading and when it arrived, measured from the start of the turn.
class _Sample {
  const _Sample(this.db, this.at);

  final double db;
  final Duration at;
}
