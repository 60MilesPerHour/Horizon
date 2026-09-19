import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/voice/stt/turn_endpointer.dart';

/// Level traces measured off real audio rather than modelled.
///
/// Each is 100 ms peak dBFS — the same thing Android's meter reports — taken
/// from a 5.8 s spoken sentence with 1.2 s of noise before and after it, so
/// speech runs from frame 12 to frame 68 and the correct place to end the
/// turn is frame ~68. The noise is pink and speech-shaped babble mixed at a
/// known SNR; the sentence itself came back verbatim from
/// faster-whisper-large-v3-turbo at every one of these levels, including the
/// 0 dB mix, which is the point: the recogniser was never the weak link,
/// endpointing was.

/// Frame at which speech stops in every trace below.
const int _speechEndsAt = 68;

const List<double> _pinkNoise10dB = [
  -22.1, -25.5, -22.9, -23.4, -23.9, -24.5, -24.0, -24.7, -26.3, -24.5,
  -26.0, -23.7, -12.0, -5.1, -8.1, -17.0, -24.7, -12.2, -14.6, -8.6, -10.1,
  -10.3, -8.3, -8.0, -16.4, -17.9, -10.8, -8.5, -14.2, -19.6, -20.5, -19.4,
  -9.9, -23.9, -23.9, -24.7, -10.8, -13.1, -8.2, -9.9, -10.2, -13.2, -16.6,
  -21.4, -7.7, -7.4, -10.8, -13.7, -6.3, -10.7, -12.9, -14.3, -16.0, -11.0,
  -11.0, -23.0, -10.2, -13.2, -10.5, -7.6, -11.9, -12.3, -11.5, -11.2,
  -16.0, -14.4, -11.4, -16.9, -25.2, -22.9, -22.5, -24.6, -24.3, -23.8,
  -23.3, -23.2, -25.5, -24.2, -23.7, -24.7, -24.0, -24.7
];

const List<double> _babble5dB = [
  -15.7, -19.9, -17.9, -17.8, -18.7, -17.3, -17.3, -19.8, -18.6, -23.2,
  -18.1, -14.0, -9.0, -5.0, -7.7, -17.3, -19.2, -12.5, -13.9, -8.5, -9.4,
  -10.6, -8.2, -8.1, -13.4, -15.0, -10.2, -9.1, -12.6, -16.6, -17.2, -16.5,
  -11.0, -15.4, -19.4, -20.3, -10.3, -12.9, -7.7, -8.8, -8.2, -11.9, -15.4,
  -19.2, -8.3, -7.7, -10.8, -12.6, -6.0, -10.5, -11.3, -12.7, -13.0, -11.9,
  -11.5, -16.1, -9.7, -11.3, -9.6, -6.1, -10.5, -12.2, -9.9, -10.8, -14.1,
  -13.8, -11.2, -14.7, -14.8, -16.2, -20.0, -20.1, -19.9, -18.7, -18.1,
  -19.3, -17.2, -17.5, -16.8, -18.6, -16.7, -15.4
];

const List<double> _babble0dB = [
  -13.7, -12.1, -12.5, -14.5, -13.4, -13.2, -13.4, -12.2, -12.6, -14.6,
  -11.9, -12.5, -9.4, -4.6, -7.5, -15.2, -11.9, -7.7, -10.4, -6.9, -9.2,
  -10.4, -7.5, -8.5, -12.2, -11.9, -8.7, -8.4, -8.7, -12.2, -17.2, -10.5,
  -9.2, -14.4, -11.4, -12.6, -10.8, -9.4, -8.3, -8.1, -7.3, -9.3, -11.5,
  -13.8, -6.0, -7.9, -8.2, -10.6, -6.3, -9.7, -8.8, -10.4, -11.3, -8.0,
  -11.3, -12.6, -8.5, -8.4, -8.0, -6.9, -9.6, -11.2, -8.6, -11.1, -11.1,
  -8.3, -10.1, -10.4, -12.3, -15.4, -12.6, -13.2, -15.0, -11.5, -11.3,
  -14.0, -12.4, -12.8, -14.4, -10.5, -11.7, -16.9
];

const List<double> _babbleNoSpeech = [
  -17.7, -17.7, -17.8, -18.8, -19.0, -19.1, -16.3, -16.5, -16.0, -18.4,
  -17.8, -19.7, -17.7, -17.1, -18.3, -15.5, -16.0, -17.6, -17.6, -19.4,
  -19.1, -17.9, -17.8, -15.7, -15.7, -16.2, -18.4, -17.2, -22.7, -19.6,
  -17.7, -18.0, -15.9, -16.2, -20.4, -18.6, -22.2, -20.5, -15.4, -16.5,
  -17.2, -16.6, -19.3, -18.9, -18.3, -18.6, -17.1, -17.3, -19.7, -18.7,
  -18.6, -17.1, -15.2, -17.3, -19.3, -17.6, -19.1, -17.9, -16.6, -16.7,
  -18.2, -20.2, -18.7, -17.4, -17.3, -17.5, -18.1, -19.2, -18.7, -18.4,
  -17.4, -16.1, -18.6, -19.2, -17.0, -17.4, -17.3, -17.6, -18.0, -16.6,
  -17.8, -21.2
];

/// "Hmm, let me think. The answer is... four. And, uh, remind me tomorrow,
/// please." — synthesised, mixed with quiet room tone, and the point of it is
/// the two 300 ms pauses *inside* the sentence (frames 30-32 and 37-39). The
/// hangover has to survive those without ending the turn. Speech runs frames
/// 12-63.
const List<double> _sentenceWithPauses = [
  -34.5, -33.2, -33.9, -32.9, -35.3, -34.6, -33.7, -35.0, -33.7, -33.8,
  -33.5, -33.7, -11.0, -8.0, -5.5, -13.2, -15.0, -7.6, -13.4, -23.7, -23.6,
  -16.5, -12.6, -10.1, -6.2, -17.1, -15.6, -17.4, -17.4, -14.1, -32.5, -33.6,
  -28.2, -6.5, -7.3, -11.4, -24.1, -33.0, -33.0, -33.5, -8.0, -9.5, -6.7,
  -4.0, -4.8, -14.2, -12.6, -12.1, -8.8, -12.1, -15.4, -15.8, -8.5, -11.9,
  -8.6, -10.4, -18.5, -17.4, -15.3, -18.7, -26.7, -18.2, -14.1, -33.1, -34.3,
  -33.9, -34.0, -34.7, -34.0, -31.8, -34.5, -34.8, -33.0, -33.1, -34.5
];

/// Frame at which speech stops in [_sentenceWithPauses].
const int _pausedSentenceEndsAt = 63;

/// Runs a trace, then keeps feeding its noise tail until the endpointer
/// decides — the traces are only 8.2 s long and the question is often *when*
/// it ends, not whether.
({TurnSignal signal, int frame}) _run(List<double> trace) {
  final endpointer = TurnEndpointer();
  for (var i = 0; i < trace.length; i++) {
    final signal = endpointer.add(trace[i]);
    if (signal != TurnSignal.listening) return (signal: signal, frame: i);
  }

  final tail = trace.sublist(_speechEndsAt);
  for (var i = 0; i < 400; i++) {
    final signal = endpointer.add(tail[i % tail.length]);
    if (signal != TurnSignal.listening) {
      return (signal: signal, frame: trace.length + i);
    }
  }
  return (signal: TurnSignal.listening, frame: -1);
}

void main() {
  test('pink noise 10 dB down: ends within a second of the last word', () {
    final result = _run(_pinkNoise10dB);
    expect(result.signal, TurnSignal.ended);
    // Frame 76 as it stands: 800 ms, i.e. the hangover plus a frame.
    expect(result.frame, greaterThan(_speechEndsAt));
    expect(result.frame - _speechEndsAt, lessThan(12));
  });

  test('speech-shaped babble 5 dB down: ends within a second of the last word',
      () {
    final result = _run(_babble5dB);
    expect(result.signal, TurnSignal.ended);
    expect(result.frame - _speechEndsAt, lessThan(12));
  });

  test('babble as loud as the speech cuts the turn short — a known limit', () {
    // 0 dB SNR is past what level metering can resolve, and this documents
    // where the wall is rather than pretending there isn't one: the room
    // measures within 4 dB of the voice, so most of the sentence is "quiet"
    // by any threshold and the turn ends mid-word.
    //
    // Two things make that survivable and both are covered elsewhere here:
    // the measured room level is what raises the "it's loud, tap when you're
    // done" notice, and a manual stop keeps the audio — which transcribes
    // perfectly, since the recogniser has no such limit.
    //
    // What matters is that it *decides*. The old gate held the microphone
    // open to its 90 s cap here, the "sometimes it takes a while to realise
    // I'm done talking" complaint.
    final endpointer = TurnEndpointer();
    var frame = 0;
    var signal = TurnSignal.listening;
    while (signal == TurnSignal.listening && frame < _babble0dB.length - 1) {
      signal = endpointer.add(_babble0dB[frame]);
      frame++;
    }
    expect(signal, TurnSignal.ended);
    expect(endpointer.noiseFloorDb, greaterThan(-22.0),
        reason: 'this is the room level the UI warns about');
  });

  test('tapping stop rescues the turn the meter could not resolve', () {
    // Whisper transcribed this exact clip verbatim, so throwing it away on a
    // deliberate stop would be losing words it could have read.
    final endpointer = TurnEndpointer();
    for (final db in _babble0dB) {
      endpointer.add(db);
    }
    expect(endpointer.finishNow(), TurnSignal.ended);
  });

  test('pauses inside a sentence do not end the turn', () {
    final endpointer = TurnEndpointer();
    for (var i = 0; i <= _pausedSentenceEndsAt; i++) {
      expect(endpointer.add(_sentenceWithPauses[i]), TurnSignal.listening,
          reason: 'ended at frame $i, mid-sentence');
    }

    var frame = _pausedSentenceEndsAt;
    var signal = TurnSignal.listening;
    while (signal == TurnSignal.listening &&
        frame < _sentenceWithPauses.length - 1) {
      frame++;
      signal = endpointer.add(_sentenceWithPauses[frame]);
    }
    expect(signal, TurnSignal.ended);
    expect(frame - _pausedSentenceEndsAt, lessThan(12));
  });

  test('babble with nothing said is never taken for a turn', () {
    final result = _run(_babbleNoSpeech);
    expect(result.signal, TurnSignal.silent,
        reason: 'uploading this is what produces a confident "Thank you." '
            'from Whisper and sends it to the model as a question');
  });
}
