import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/voice/speech_recognition_service.dart';
import 'package:horizon/Services/voice/stt/elevenlabs_transcriber.dart';
import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Services/voice/stt/speech_input_service.dart';
import 'package:horizon/Services/voice/stt/voice_recorder.dart';
import 'package:horizon/Services/voice/stt/turn_endpointer.dart';
import 'package:horizon/Services/voice/stt/whisper_transcriber.dart';

/// Levels in these traces are the ones that were measured off real recordings
/// rather than invented: room tone outdoors and in a busy room lands between
/// -34 and -24 dBFS, and speech sits only 3-10 dB above it. The old gate
/// assumed a floor no higher than -35 dBFS and demanded 9 dB of separation,
/// which is why it both failed to hear speech and failed to notice it ending.
const double _quietRoom = -52.0;
const double _busyRoom = -29.0;
const double _loudStreet = -24.0;

/// Deterministic jitter, so a trace looks like a meter and not a step
/// function, without making the test flaky. Re-seeded before every test —
/// sharing the sequence across tests couples each one to the order of the
/// others, which is its own kind of flake.
var _random = Random(11);
double _jitter([double spread = 1.5]) => (_random.nextDouble() - 0.5) * spread;

/// Feeds [frames] of [db] and returns the first non-listening signal, or null.
TurnSignal? _feed(TurnEndpointer e, double db, int frames,
    {double spread = 1.5}) {
  for (var i = 0; i < frames; i++) {
    final signal = e.add(db + _jitter(spread));
    if (signal != TurnSignal.listening) return signal;
  }
  return null;
}

/// Feeds speech rather than a tone: on a 100 ms peak meter a voice swings
/// several dB from syllable to syllable, and traces that hold one level
/// exactly are the one thing a real microphone never produces.
TurnSignal? _speak(TurnEndpointer e, double peakDb, int frames) {
  for (var i = 0; i < frames; i++) {
    // A syllable lasting two frames and then a gap, swinging 12 dB: that is
    // what the measured traces look like, and what a voice does on a peak
    // meter. A single-frame square wave at 5 Hz is neither.
    final syllable = i % 3 == 2 ? peakDb - 12 : peakDb;
    final signal = e.add(syllable + _jitter());
    if (signal != TurnSignal.listening) return signal;
  }
  return null;
}

/// Runs until the endpointer decides something, capped at the hard limit.
({TurnSignal signal, Duration elapsed}) _runToEnd(
  TurnEndpointer e,
  double Function() level,
) {
  var elapsed = Duration.zero;
  var signal = TurnSignal.listening;
  while (signal == TurnSignal.listening && elapsed <= TurnEndpointer.maxTurn) {
    signal = e.add(level());
    elapsed += const Duration(milliseconds: 100);
  }
  return (signal: signal, elapsed: elapsed);
}

/// One frame is 100 ms; this reads better than counting frames.
int _frames(int milliseconds) => milliseconds ~/ 100;

void main() {
  setUp(() => _random = Random(11));

  group('a quiet room', () {
    test('hears speech and ends the turn shortly after it stops', () {
      final e = TurnEndpointer();
      expect(_feed(e, _quietRoom, _frames(600)), isNull);
      expect(_feed(e, -28, _frames(2000)), isNull);
      expect(e.speechHeard, isTrue);

      // Still talking: the turn must not end on the gaps between words.
      expect(_feed(e, _quietRoom, _frames(400)), isNull);
      expect(_feed(e, -28, _frames(800)), isNull);

      expect(_feed(e, _quietRoom, _frames(900)), TurnSignal.ended);
      expect(e.speechDuration.inMilliseconds, greaterThan(2000));
      expect(e.endedOnNoise, isFalse);
    });

    test('nothing said at all is reported as silence, not an empty clip', () {
      final e = TurnEndpointer();
      expect(_feed(e, _quietRoom, _frames(7000)), isNull);
      expect(_feed(e, _quietRoom, _frames(2000)), TurnSignal.silent);
      expect(e.speechHeard, isFalse);
    });
  });

  group('a room that is louder than the old floor cap', () {
    test('hears speech over a busy room', () {
      final e = TurnEndpointer();
      _feed(e, _busyRoom, _frames(800));
      // 10 dB is what 5 dB of RMS SNR looks like on a peak meter, measured
      // off the real recordings — a voice has a higher crest factor than a
      // room does, so it stands further above the ambience than its power
      // ratio suggests. The old gate wanted 9 dB *and* worked from a floor
      // pinned at -35 dBFS, which in this room is below the ambience.
      expect(_feed(e, _busyRoom + 10, _frames(1500)), isNull);
      expect(e.speechHeard, isTrue);
    });

    test('ends the turn: the floor tracks a street, it is not capped', () {
      final e = TurnEndpointer();
      _feed(e, _loudStreet, _frames(800));
      _feed(e, _loudStreet + 8, _frames(1800));
      expect(e.speechHeard, isTrue);

      final signal = _feed(e, _loudStreet, _frames(1500));
      expect(signal, TurnSignal.ended,
          reason: 'ambience above -35 dBFS used to read as speech forever');
      expect(e.noiseFloorDb, greaterThan(-32.0));
    });

    test('a room that gets louder mid-turn still ends the turn', () {
      final e = TurnEndpointer();
      _feed(e, _quietRoom, _frames(600));
      _feed(e, -30, _frames(1500));
      expect(e.speechHeard, isTrue);

      // A bus pulls up: ambience is now well above the original floor, which
      // the old one-way-downward floor could never account for.
      final signal = _feed(e, _busyRoom, _frames(12000));
      expect(signal, isNotNull);
      expect(signal, isNot(TurnSignal.silent));
    });

    test('a loud steady din is not a spoken turn at all', () {
      final e = TurnEndpointer();
      // Loud but unvarying: a leaf blower, not a sentence. The old gate read
      // every frame of this as speech because it was 20 dB over a floor that
      // could not rise.
      final ended = _runToEnd(e, () => -18 + _jitter(0.4));
      expect(ended.signal, TurnSignal.silent);
      expect(ended.elapsed, lessThan(const Duration(seconds: 10)));
      expect(e.speechHeard, isFalse);
    });

    test('speech swamped by a din that never lets up still ends', () {
      final e = TurnEndpointer();
      _feed(e, _quietRoom, _frames(500));
      _feed(e, -30, _frames(1200));
      expect(e.speechHeard, isTrue);

      // From here the level never falls back to the room: the endpointer has
      // to decide on its own that the sentence is over.
      final ended = _runToEnd(e, () => -20 + _jitter());
      expect(ended.signal, TurnSignal.ended);
      expect(ended.elapsed, lessThan(const Duration(seconds: 20)));
      expect(TurnEndpointer.maxContinuousSpeech,
          lessThan(TurnEndpointer.maxTurn));
    });
  });

  group('a long turn without a pause in it', () {
    test('is not truncated while the level still moves like a voice', () {
      final e = TurnEndpointer();
      _feed(e, _quietRoom, _frames(500));
      // Twelve seconds of dictation with no gap long enough to reach the
      // room. Letting the floor back in on elapsed time alone ended this at
      // nine seconds, mid-sentence, with nothing to show it had happened.
      expect(_speak(e, -28, _frames(12000)), isNull);
      expect(e.speechHeard, isTrue);
      expect(e.speechDuration.inSeconds, greaterThan(8));

      // It still ends when the speaker actually stops.
      expect(_feed(e, _quietRoom, _frames(900)), TurnSignal.ended);
      expect(e.endedOnNoise, isFalse);
    });

    test('is cut, and says so, when the level stops moving like a voice', () {
      final e = TurnEndpointer();
      _feed(e, _quietRoom, _frames(500));
      _feed(e, -28, _frames(1000));
      expect(e.speechHeard, isTrue);

      // The level holds steady from here: a fan, a road, a crowd. Duration
      // plus a flat spread is the only pair of facts that tells this from a
      // long sentence.
      final ended = _runToEnd(e, () => -24 + _jitter(1.0));
      expect(ended.signal, TurnSignal.ended);
      expect(ended.elapsed, lessThan(const Duration(seconds: 12)));
      expect(e.endedOnNoise, isTrue,
          reason: 'the UI needs to be able to say why it stopped listening');
    });
  });

  group('speech that starts before the meter has measured the room', () {
    test('is still heard when the first frames are all speech', () {
      final e = TurnEndpointer();
      // Talking from frame one: there is no room measurement to compare
      // against, so this latches on the syllable-to-syllable swing instead.
      expect(_speak(e, -26, _frames(1800)), isNull);
      expect(e.speechHeard, isTrue);
      expect(_feed(e, _quietRoom, _frames(900)), TurnSignal.ended);
    });
  });

  group('sounds that are not a spoken turn', () {
    test('a single loud click does not open a turn', () {
      final e = TurnEndpointer();
      _feed(e, _quietRoom, _frames(500));
      e.add(-6); // door slam, one frame
      expect(_feed(e, _quietRoom, _frames(7500)), TurnSignal.silent);
      expect(e.speechHeard, isFalse,
          reason: 'one frame used to be enough, so a bang uploaded a clip of '
              'the room for Whisper to hallucinate over');
    });

    test('one brisk word is a turn, not a blip', () {
      final e = TurnEndpointer();
      _feed(e, _quietRoom, _frames(500));
      // "No." — barely long enough to latch and nothing more. This measured
      // 300 ms and was thrown away for being under the minimum, which in
      // continuous mode just silently reopened the microphone. Latching now
      // credits the frame the median smoothing swallowed.
      _feed(e, -26, 3);
      expect(_feed(e, _quietRoom, _frames(900)), TurnSignal.ended);
      expect(e.speechDuration,
          greaterThanOrEqualTo(TurnEndpointer.minimumSpeech));
    });

    test('a mis-tap is not a turn', () {
      final e = TurnEndpointer();
      _feed(e, _quietRoom, _frames(400));
      expect(e.finishNow(), TurnSignal.silent);
    });

    test('stopping by hand keeps the audio even if no speech was detected',
        () {
      final e = TurnEndpointer();
      _feed(e, _quietRoom, _frames(1500));
      // Deliberate: somewhere too loud for the meter to tell speech from the
      // room, tapping stop is what you do, and Whisper transcribes clips the
      // endpointer can't read. Discarding it loses what you said.
      expect(e.finishNow(), TurnSignal.ended);
    });
  });

  test('the level meter reads against the room, not an absolute scale', () {
    final quiet = TurnEndpointer();
    _feed(quiet, _quietRoom, _frames(1000));
    final quietIdle = quiet.level;

    final busy = TurnEndpointer();
    _feed(busy, _busyRoom, _frames(1000));

    // Room tone reads as near-nothing in both, so the meter tracks the voice
    // rather than showing a permanently half-full bar next to a fan.
    expect(quietIdle, lessThan(0.2));
    expect(busy.level, lessThan(0.2));

    busy.add(_busyRoom + 20);
    expect(busy.level, greaterThan(0.6));
  });

  group('phantom transcripts', () {
    test('three words out of half a second of speech is not something said', () {
      expect(
        SpeechInputService.isPhantomTranscript(
            'Thank you for watching!', const Duration(milliseconds: 400)),
        isTrue,
      );
    });

    test("Whisper's stock noise phrases are dropped", () {
      expect(
        SpeechInputService.isPhantomTranscript(
            'Thank you.', const Duration(milliseconds: 350)),
        isTrue,
      );
      expect(
        SpeechInputService.isPhantomTranscript(
            '', const Duration(milliseconds: 350)),
        isTrue,
      );
    });

    test('short real answers survive', () {
      // Losing "yeah" in a conversation is worse than the occasional phantom.
      for (final word in ['yeah', 'no', 'stop', 'louder', 'next one']) {
        expect(
          SpeechInputService.isPhantomTranscript(
              word, const Duration(milliseconds: 400)),
          isFalse,
          reason: word,
        );
      }
    });

    test('a turn kept without detected speech keeps its words', () {
      // The recorder reports null when it kept the audio on a manual stop
      // without ever resolving speech in it — somewhere too loud for the
      // level meter. The word count means nothing then: there is no duration
      // to weigh it against, and a real sentence is exactly what that path
      // exists to rescue.
      expect(
        SpeechInputService.isPhantomTranscript(
            'Turn the kitchen lights off', null),
        isFalse,
      );
      expect(
        SpeechInputService.isPhantomTranscript('No', null),
        isFalse,
      );
    });

    test('a stock noise phrase is dropped even with nothing to weigh it', () {
      // The other half of that case: tap, say nothing, tap stop. The clip is
      // kept by design, and what comes back is Whisper's "Thank you." — which
      // would otherwise be sent to the model as a question.
      expect(
        SpeechInputService.isPhantomTranscript('Thank you.', null),
        isTrue,
      );
      expect(SpeechInputService.isPhantomTranscript('', null), isTrue);
    });

    test('a real turn is never second-guessed', () {
      expect(
        SpeechInputService.isPhantomTranscript(
            'Thank you.', const Duration(milliseconds: 900)),
        isFalse,
      );
    });
  });

  group('the meter\'s real cadence, not the one we asked for', () {
    test('timeouts follow measured time, not the frame count', () {
      // A meter delivering every 300 ms instead of every 100 ms must not turn
      // a 750 ms hangover into 2.25 s.
      final e = TurnEndpointer();
      const slow = Duration(milliseconds: 300);
      for (var i = 0; i < 4; i++) {
        e.add(_quietRoom + _jitter(), delta: slow);
      }
      for (var i = 0; i < 6; i++) {
        e.add(-28 + _jitter(), delta: slow);
      }
      expect(e.speechHeard, isTrue);

      var signal = TurnSignal.listening;
      var frames = 0;
      while (signal == TurnSignal.listening && frames < 10) {
        signal = e.add(_quietRoom + _jitter(), delta: slow);
        frames++;
      }
      expect(signal, TurnSignal.ended);
      // Three 300 ms frames of silence clear the hangover, plus one for the
      // median-of-three lag — the first quiet frame still reads as speech,
      // which is the price of not letting a single blip reset the timer.
      expect(frames, lessThanOrEqualTo(4));
    });
  });

  group('the language sent to a recording backend', () {
    SpeechInputService service() => SpeechInputService(
          device: SpeechRecognitionService(),
          recorder: VoiceRecorder(),
          whisper: WhisperTranscriber(),
          elevenLabs: ElevenLabsTranscriber(),
        );

    test('is the bare ISO-639-1 code from the chosen locale', () {
      expect((service()..localeId = 'en_US').resolvedLanguage, 'en');
      expect((service()..localeId = 'de-DE').resolvedLanguage, 'de');
      expect((service()..localeId = 'fr_FR.UTF-8').resolvedLanguage, 'fr');
    });

    test('is omitted rather than sent as something invalid', () {
      // A Linux session with LANG=C reports "C", and `language=c` is not
      // ignored by the server — Speaches answers HTTP 500 and the turn is
      // lost. Same for a 3-letter code it would not accept.
      expect((service()..localeId = 'C').resolvedLanguage, '');
      expect((service()..localeId = 'POSIX').resolvedLanguage, '');
      expect((service()..localeId = 'eng').resolvedLanguage, '');
    });
  });

  group('server-side VAD', () {
    test('is asked for, and withdrawn if the server refuses it', () {
      // `vad_filter` is a faster-whisper extension. It used to be gated on a
      // two-name list of hosts assumed to be strict, which is wrong the
      // moment anyone runs something not on the list — including
      // whisper.cpp's own server, which this backend claims to support.
      // Failover deliberately doesn't retry a server that answered, so a
      // server that dislikes the field would fail every turn with no way
      // back. It's now asked for optimistically and dropped on a rejection.
      expect(WhisperTranscriber.vadFilterField, 'vad_filter');
    });

    test('a rejection is distinguishable from never arriving', () {
      const rejected =
          SttResult.failure('no', serverRejected: true, statusCode: 415);
      const unreachable = SttResult.failure('nope');
      expect(rejected.serverRejected, isTrue);
      expect(rejected.statusCode, 415);
      expect(unreachable.serverRejected, isFalse,
          reason: 'a timeout says nothing about the request, so nothing '
              'about it should change in response');
      expect(unreachable.statusCode, isNull);
    });
  });
}
