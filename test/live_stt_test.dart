import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Services/voice/stt/mic_pcm_stream.dart';
import 'package:horizon/Services/voice/stt/speech_input_backend.dart';
import 'package:horizon/Services/voice/stt/whisper_live_client.dart';

void main() {
  group('WhisperLive segment folding', () {
    late WhisperLiveClient client;

    setUp(() {
      client = WhisperLiveClient(baseUrl: 'http://192.168.1.5:9090');
    });

    test('a revisable tail replaces itself rather than accumulating', () {
      // The server resends its whole window every update, which it does every
      // 100-200 ms while someone is talking. Appending instead of replacing
      // is the bug this exists to prevent.
      client.applySegments([
        {'start': '0.000', 'end': '1.0', 'text': 'Hello, this is a', 'completed': false},
      ]);
      expect(client.current.text, 'Hello, this is a');

      client.applySegments([
        {'start': '0.000', 'end': '1.4', 'text': 'Hello, this is a test of', 'completed': false},
      ]);
      expect(client.current.text, 'Hello, this is a test of');
      expect(client.current.committed, isEmpty);
    });

    test('completed segments settle and the tail moves on', () {
      client.applySegments([
        {'start': '0.000', 'text': 'Hello, this is a test.', 'completed': true},
        {'start': '2.680', 'text': 'I am che-', 'completed': false},
      ]);
      expect(client.current.committed, 'Hello, this is a test.');
      expect(client.current.tail, 'I am che-');
      expect(client.current.text, 'Hello, this is a test. I am che-');
    });

    test('a resent completed segment updates in place', () {
      // Observed against the running server: the final update re-cuts the
      // segment, arriving with a *different* start time for the same words.
      // Keying by start means that lands as a second segment, so the text has
      // to be the thing that settles, not the count.
      client.applySegments([
        {'start': '0.000', 'text': 'Hello there', 'completed': true},
      ]);
      client.applySegments([
        {'start': '0.000', 'text': 'Hello there.', 'completed': true},
      ]);
      expect(client.current.committed, 'Hello there.');
    });

    test('empty and whitespace-only segments are ignored', () {
      client.applySegments([
        {'start': '0.000', 'text': '   ', 'completed': false},
        {'start': '1.000', 'text': '', 'completed': true},
      ]);
      expect(client.current.isEmpty, isTrue);
    });

    test('malformed entries do not take the turn down', () {
      client.applySegments(['nonsense', 42, null, {'text': 'still here'}]);
      expect(client.current.text, 'still here');
    });

    test('start times arrive as strings, and sort numerically', () {
      // They really are strings on the wire — '10.000' before '9.000' under a
      // lexicographic sort, which would reorder the sentence.
      client.applySegments([
        {'start': '9.000', 'text': 'second', 'completed': true},
        {'start': '10.000', 'text': 'third', 'completed': true},
        {'start': '0.000', 'text': 'first', 'completed': true},
      ]);
      expect(client.current.committed, 'first second third');
    });
  });

  group('WhisperLive address handling', () {
    test('a LAN address becomes ws, a hostname becomes wss', () {
      expect(
        WhisperLiveClient.websocketUrl('http://172.16.23.20:9090').toString(),
        'ws://172.16.23.20:9090',
      );
      expect(
        WhisperLiveClient.websocketUrl('172.16.23.20:9090').toString(),
        'ws://172.16.23.20:9090',
      );
      expect(
        WhisperLiveClient.websocketUrl('live.example.com').toString(),
        'wss://live.example.com',
      );
      expect(
        WhisperLiveClient.websocketUrl('https://live.example.com/').toString(),
        'wss://live.example.com',
      );
    });

    test('an unconfigured client reports itself as such', () {
      expect(WhisperLiveClient().isConfigured, isFalse);
      expect(WhisperLiveClient(backupUrl: 'live.example.com').isConfigured, isTrue);
    });
  });

  group('PCM conversion', () {
    test('int16 little-endian becomes float32 in range', () {
      final bytes = Uint8List.fromList([
        0x00, 0x00, // 0
        0x00, 0x40, // 16384 -> 0.5
        0x00, 0xC0, // -16384 -> -0.5
      ]);
      final frame = MicPcmStream.toFloat32(bytes);
      expect(frame.length, 3);
      expect(frame[0], 0.0);
      expect(frame[1], closeTo(0.5, 1e-6));
      expect(frame[2], closeTo(-0.5, 1e-6));
    });

    test('an odd trailing byte is dropped, not padded', () {
      // Half a sample at a frame boundary: the next frame carries its other
      // half, and inventing a zero for it puts a click in every frame.
      final frame = MicPcmStream.toFloat32(Uint8List.fromList([0x00, 0x40, 0x11]));
      expect(frame.length, 1);
    });

    test('silence reads as the floor rather than negative infinity', () {
      expect(MicPcmStream.rmsDb(Float32List(160)), MicPcmStream.silenceDb);
      expect(MicPcmStream.rmsDb(Float32List(0)), MicPcmStream.silenceDb);
    });

    test('full scale reads as 0 dBFS, and speech well below it', () {
      final loud = Float32List.fromList(List.filled(160, 1.0));
      expect(MicPcmStream.rmsDb(loud), closeTo(0.0, 0.01));

      // A quarter of full scale is about -12 dBFS: comfortably above the
      // floor, comfortably below clipping.
      final talking = Float32List.fromList(List.filled(160, 0.25));
      expect(MicPcmStream.rmsDb(talking), closeTo(-12.04, 0.1));
    });
  });

  group('WAV packaging', () {
    test('header describes the audio that follows', () {
      final frames = [
        Float32List.fromList([0.0, 0.5]),
        Float32List.fromList([-0.5]),
      ];
      final wav = MicPcmStream.toWav(frames);
      final view = ByteData.sublistView(wav);

      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(view.getUint16(20, Endian.little), 1); // PCM
      expect(view.getUint16(22, Endian.little), 1); // mono
      expect(view.getUint32(24, Endian.little), MicPcmStream.sampleRate);
      expect(view.getUint16(34, Endian.little), 16); // bits per sample
      expect(view.getUint32(40, Endian.little), 6); // three samples
      expect(wav.length, 44 + 6);
      expect(view.getInt16(44, Endian.little), 0);
      expect(view.getInt16(46, Endian.little), 16384); // 0.5
      expect(view.getInt16(48, Endian.little), -16384);
    });

    test('samples beyond full scale are clamped, not wrapped', () {
      // Wrapping turns a loud moment into a burst of noise at the opposite
      // polarity, which transcribes as nothing at all.
      final wav = MicPcmStream.toWav([Float32List.fromList([2.0, -2.0])]);
      final view = ByteData.sublistView(wav);
      expect(view.getInt16(44, Endian.little), 32767);
      expect(view.getInt16(46, Endian.little), -32767);
    });

    test('no frames means no file', () {
      expect(MicPcmStream.toWav(const []).length, 44);
    });
  });

  sharedHostnameTests();

  group('backend capabilities', () {
    test('live round-trips through storage and shows live words', () {
      expect(SttBackend.fromString('live'), SttBackend.live);
      expect(SttBackend.live.storageValue, 'live');
      expect(SttBackend.live.hasPartialResults, isTrue);
      expect(SttBackend.live.needsRecording, isTrue);
      expect(SttBackend.live.uploadsClip, isFalse);
    });

    test('the upload backends still own their clip and their endpointing', () {
      expect(SttBackend.whisper.uploadsClip, isTrue);
      expect(SttBackend.elevenLabs.uploadsClip, isTrue);
      expect(SttBackend.device.needsRecording, isFalse);
      expect(SttBackend.device.uploadsClip, isFalse);
    });
  });
}

void sharedHostnameTests() {
  group('sharing a hostname with the speech stack', () {
    test('the live address is derived from the transcription address', () {
      expect(
        WhisperLiveClient.sharedWith('https://speech.example.com'),
        'https://speech.example.com/live',
      );
      expect(
        WhisperLiveClient.sharedWith('172.16.23.20:8001'),
        'http://172.16.23.20:8001/live',
      );
      // Idempotent: settings can re-derive without stacking paths.
      expect(
        WhisperLiveClient.sharedWith('https://speech.example.com/live'),
        'https://speech.example.com/live',
      );
      expect(WhisperLiveClient.sharedWith(''), isEmpty);
    });

    test('a path on the address survives into the websocket url', () {
      expect(
        WhisperLiveClient.websocketUrl('https://speech.example.com/live')
            .toString(),
        'wss://speech.example.com/live',
      );
      expect(
        WhisperLiveClient.websocketUrl('http://172.16.23.20:8001/live')
            .toString(),
        'ws://172.16.23.20:8001/live',
      );
    });
  });

  group('WhisperLive connect failover', () {
    final servers = <HttpServer>[];
    tearDown(() async {
      for (final server in servers) {
        await server.close(force: true);
      }
      servers.clear();
    });

    Future<String> serve(void Function(HttpRequest) handler) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      servers.add(server);
      server.listen(handler);
      return 'http://127.0.0.1:${server.port}';
    }

    test('a refused handshake moves on to the remote address', () async {
      // What a hotel network on the same private range, a captive portal or
      // Access does: answer over HTTP instead of upgrading.
      final refusing = await serve((req) {
        req.response.statusCode = HttpStatus.forbidden;
        req.response.close();
      });
      final live = await serve((req) async {
        final socket = await WebSocketTransformer.upgrade(req);
        socket.listen((frame) {
          if (frame is String) {
            final uid = json.decode(frame)['uid'];
            socket.add(json.encode({'uid': uid, 'message': 'SERVER_READY'}));
          }
        });
      });

      final client = WhisperLiveClient(baseUrl: refusing, backupUrl: live);
      expect(await client.connect(), isTrue);
      expect(client.isOnBackup, isTrue);
      expect(client.lastError, isNull);
      await client.dispose();
    });

    test('a failure off the LAN with no remote address says so', () async {
      final refusing = await serve((req) {
        req.response.statusCode = HttpStatus.forbidden;
        req.response.close();
      });
      final client = WhisperLiveClient(baseUrl: refusing);
      expect(await client.connect(), isFalse);
      expect(client.lastError, contains('refused'));
      await client.dispose();

      // Nothing listening: a transport failure, with the missing backup named.
      final dead = WhisperLiveClient(baseUrl: 'http://127.0.0.1:1');
      expect(await dead.connect(), isFalse);
      expect(dead.lastError, contains('Address from anywhere'));
      await dead.dispose();
    });
  });
}
