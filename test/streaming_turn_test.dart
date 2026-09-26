import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/voice/stt/mic_pcm_stream.dart';
import 'package:horizon/Services/voice/stt/streaming_speech_session.dart';
import 'package:horizon/Services/voice/stt/whisper_live_client.dart';
import 'package:horizon/Services/voice/stt/whisper_transcriber.dart';

/// A microphone that plays back whatever the test pushes into it.
class _FakeMic extends MicPcmStream {
  final _out = StreamController<Float32List>.broadcast();
  int _samples = 0;

  @override
  Stream<Float32List> get frames => _out.stream;
  @override
  Duration get captured =>
      Duration(microseconds: _samples * 1000000 ~/ MicPcmStream.sampleRate);
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<bool> start() async {
    _samples = 0;
    return true;
  }

  @override
  Future<void> stop() async {}

  /// 100 ms of a tone at [db] dBFS RMS.
  void push(double db) {
    final amp = math.pow(10, db / 20).toDouble() * math.sqrt2;
    final frame = Float32List(1600);
    for (var i = 0; i < frame.length; i++) {
      frame[i] = amp * math.sin(2 * math.pi * 220 * (_samples + i) / 16000);
    }
    _samples += frame.length;
    _out.add(frame);
  }
}

/// A WhisperLive server the test answers for.
class _FakeServer extends WhisperLiveClient {
  _FakeServer() : super(baseUrl: 'http://fake:9090');

  final ready = Completer<bool>();
  final sent = <Float32List>[];
  final _t = StreamController<LiveTranscript>.broadcast();
  final _e = StreamController<String>.broadcast();
  LiveTranscript _now = const LiveTranscript();

  @override
  Stream<LiveTranscript> get transcripts => _t.stream;
  @override
  Stream<String> get errors => _e.stream;
  @override
  LiveTranscript get current => _now;
  @override
  Future<bool> connect({String? languageCode}) => ready.future;
  @override
  void send(Float32List frame) => sent.add(frame);
  @override
  Future<LiveTranscript> finish({
    Duration settle = Duration.zero,
    Duration grace = Duration.zero,
  }) async =>
      _now;
  @override
  Future<void> close() async {}

  void say(String text) {
    _now = LiveTranscript(tail: text);
    _t.add(_now);
  }
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('speech during a cold connect is buffered and sent once ready',
      () async {
    final mic = _FakeMic();
    final server = _FakeServer();
    final session = StreamingSpeechSession(mic: mic, client: server);

    final turn = session.run(onPartial: (_) {});
    await _tick();
    for (var i = 0; i < 20; i++) {
      mic.push(-25);
    }
    expect(server.sent, isEmpty, reason: 'nothing goes up before READY');

    server.ready.complete(true);
    await _tick();
    await _tick();
    expect(server.sent.length, 20, reason: 'the backlog is flushed');

    mic.push(-25);
    await _tick();
    expect(server.sent.length, 21, reason: 'and live frames follow it');

    session.cancel();
    expect((await turn).outcome, StreamingTurnOutcome.cancelled);
  });

  test('in a room as loud as the voice, a settled transcript ends the turn',
      () async {
    final mic = _FakeMic();
    final server = _FakeServer()..ready.complete(true);
    final session = StreamingSpeechSession(mic: mic, client: server);

    final turn = session.run(onPartial: (_) {});
    await _tick();
    await _tick();

    // A flat, loud room: the level meter never hears a sentence in it.
    var done = false;
    unawaited(turn.then((_) => done = true));
    for (var i = 0; i < 10; i++) {
      mic.push(-20);
    }
    server.say('what is the weather');
    for (var i = 0; i < 4; i++) {
      mic.push(-20);
      server.say('what is the weather tomorrow');
    }
    // Still changing a moment ago — not over yet.
    await _tick();
    expect(done, isFalse);

    // Unchanged and repeated for longer than the loud-room settle time.
    for (var i = 0; i < 24; i++) {
      mic.push(-20);
      server.say('what is the weather tomorrow');
      await _tick();
    }
    final result = await turn.timeout(const Duration(seconds: 2));
    expect(result.outcome, StreamingTurnOutcome.spoken);
    expect(result.text, 'what is the weather tomorrow');
  });

  test('in a quiet room the turn ends about half a second after speech',
      () async {
    final mic = _FakeMic();
    final server = _FakeServer()..ready.complete(true);
    final session = StreamingSpeechSession(mic: mic, client: server);

    final turn = session.run(onPartial: (_) {});
    await _tick();
    await _tick();
    for (var i = 0; i < 5; i++) {
      mic.push(-60);
      await _tick();
    }
    for (var i = 0; i < 15; i++) {
      mic.push(i.isEven ? -20 : -26);
      server.say('turn on the kitchen lights'.substring(0, 10 + i));
      await _tick();
    }
    var quietFrames = 0;
    var done = false;
    unawaited(turn.then((_) => done = true));
    while (!done && quietFrames < 30) {
      mic.push(-60);
      server.say('turn on the kitchen lights');
      quietFrames++;
      await _tick();
      await _tick();
    }
    final result = await turn.timeout(const Duration(seconds: 2));
    expect(result.outcome, StreamingTurnOutcome.spoken);
    expect(quietFrames, lessThanOrEqualTo(8),
        reason: 'ended ${quietFrames * 100} ms after the last syllable');
  });

  test('a live server that hears no words calls the turn silent', () async {
    final mic = _FakeMic();
    final server = _FakeServer()..ready.complete(true);
    final session = StreamingSpeechSession(mic: mic, client: server);

    final turn = session.run(onPartial: (_) {});
    await _tick();
    await _tick();
    // Loud, speech-like level bursts, but the server transcribes nothing —
    // a television. Held past the quiet timeout, ended by the hard cap.
    for (var i = 0; i < 160; i++) {
      mic.push(i.isEven ? -15 : -30);
      await _tick();
    }
    final result = await turn.timeout(const Duration(seconds: 2));
    expect(result.outcome, StreamingTurnOutcome.silent);
  });

  test('speech arriving late is not cut off by the no-words timeout',
      () async {
    final mic = _FakeMic();
    final server = _FakeServer()..ready.complete(true);
    final session = StreamingSpeechSession(mic: mic, client: server);

    var done = false;
    final turn = session.run(onPartial: (_) {});
    unawaited(turn.then((_) => done = true));
    await _tick();
    await _tick();
    // 7.5 s of a quiet room, then someone starts talking just before the
    // timeout — the case from a real recording.
    for (var i = 0; i < 75; i++) {
      mic.push(-70);
      await _tick();
    }
    for (var i = 0; i < 15; i++) {
      mic.push(i.isEven ? -32 : -40);
      await _tick();
    }
    expect(done, isFalse, reason: 'still hearing sound at 9 s');
    server.say('how old is josh johnson');
    for (var i = 0; i < 12; i++) {
      mic.push(-70);
      server.say('how old is josh johnson');
      await _tick();
      await _tick();
    }
    final result = await turn.timeout(const Duration(seconds: 2));
    expect(result.outcome, StreamingTurnOutcome.spoken);
  });

  test('a held microphone gives a new turn what was said just before it',
      () async {
    final mic = _FakeMic();
    final server = _FakeServer()..ready.complete(true);
    final session = StreamingSpeechSession(mic: mic, client: server);
    expect(await session.hold(), isTrue);
    // The start of a sentence, spoken before the turn begins.
    for (var i = 0; i < 4; i++) {
      mic.push(-20);
      await _tick();
    }
    final turn = session.run(onPartial: (_) {});
    await _tick();
    await _tick();
    expect(server.sent.length, 4, reason: 'the pre-roll reached the server');
    session.cancel();
    await turn;
    expect(mic.isRunning || session.isHeld, isTrue, reason: 'still held after the turn');
  });

  test('nothing heard while the assistant talks goes into the pre-roll', () async {
    final mic = _FakeMic();
    final server = _FakeServer()..ready.complete(true);
    final session = StreamingSpeechSession(mic: mic, client: server);
    await session.hold();
    session.echoing = true;
    for (var i = 0; i < 4; i++) {
      mic.push(-20);
      await _tick();
    }
    session.echoing = false;
    final turn = session.run(onPartial: (_) {});
    await _tick();
    await _tick();
    expect(server.sent, isEmpty);
    session.cancel();
    await turn;
  });

  test('an unreachable server hands back the clip when it can be recovered',
      () async {
    final mic = _FakeMic();
    final server = _FakeServer()..ready.complete(false);
    final session = StreamingSpeechSession(mic: mic, client: server);

    final turn = session.run(onPartial: (_) {}, canRecover: true);
    await _tick();
    await _tick();
    for (var i = 0; i < 5; i++) {
      mic.push(-60);
    }
    for (var i = 0; i < 15; i++) {
      mic.push(i.isEven ? -20 : -28);
    }
    for (var i = 0; i < 15; i++) {
      mic.push(-60);
    }
    final result = await turn.timeout(const Duration(seconds: 2));
    expect(result.outcome, StreamingTurnOutcome.spoken);
    expect(result.serverLost, isTrue);
    expect(result.audio, isNotNull);
  });

  test('without a recovery path an unreachable server is reported', () async {
    final mic = _FakeMic();
    final server = _FakeServer()..ready.complete(false);
    final session = StreamingSpeechSession(mic: mic, client: server);

    final result = await session
        .run(onPartial: (_) {})
        .timeout(const Duration(seconds: 2));
    expect(result.outcome, StreamingTurnOutcome.unavailable);
  });

  group('trailing filler', () {
    test('Whisper\'s " end." after a sentence is dropped', () {
      final client = WhisperLiveClient(baseUrl: 'http://fake:9090');
      client.applySegments([
        {'start': '0.000', 'text': ' Hey, what is the weather?', 'completed': true},
        {'start': '3.580', 'text': ' end.', 'completed': true},
      ]);
      expect(client.current.text, 'Hey, what is the weather?');

      client.applySegments([
        {'start': '0.000', 'text': ' Hey, what is the weather?', 'completed': true},
        {'start': '3.580', 'text': ' end.', 'completed': false},
      ]);
      expect(client.current.text, 'Hey, what is the weather?');
      expect(client.current.tail, isEmpty);
    });

    test('a filler on its own is left for the phantom check', () {
      final client = WhisperLiveClient(baseUrl: 'http://fake:9090');
      client.applySegments([
        {'start': '0.000', 'text': ' Thank you.', 'completed': true},
      ]);
      expect(client.current.text, 'Thank you.');
    });
  });

  group('accurate pass', () {
    test('segments Whisper rates as unlikely speech are dropped', () {
      final text = WhisperTranscriber.confidentText({
        'text': 'Hey, what is the weather tomorrow? Yeah, yeah.',
        'segments': [
          {'text': ' Hey, what is the weather tomorrow?', 'avg_logprob': -0.3, 'no_speech_prob': 0.01, 'compression_ratio': 0.9},
          {'text': ' Yeah, yeah.', 'avg_logprob': -1.3, 'no_speech_prob': 0.7, 'compression_ratio': 0.8},
        ],
      });
      expect(text, 'Hey, what is the weather tomorrow?');
    });

    test('a server without segments still gives its text', () {
      expect(WhisperTranscriber.confidentText({'text': ' hello there '}), 'hello there');
    });
  });
}
