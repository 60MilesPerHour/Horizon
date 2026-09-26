import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'package:horizon/Utils/remote_endpoint.dart';

/// What the streaming recogniser has heard so far in this turn.
///
/// Split rather than one string because the two halves deserve different
/// treatment on screen: [committed] is text the server has finalised and will
/// not revise, [tail] is its current best guess at the words still being
/// spoken and can change on the next frame. Showing the tail dimmed is what
/// makes live transcription read as honest rather than as flickering.
class LiveTranscript {
  const LiveTranscript({this.committed = '', this.tail = ''});

  final String committed;
  final String tail;

  /// Everything heard, for sending to the model.
  String get text => [committed.trim(), tail.trim()]
      .where((part) => part.isNotEmpty)
      .join(' ')
      .trim();

  bool get isEmpty => text.isEmpty;
}

/// Streaming speech-to-text against a WhisperLive server.
///
/// WhisperLive (MIT, Collabora) is a WebSocket front end to faster-whisper
/// that transcribes a *sliding window of audio while it is still arriving*,
/// resending its current hypothesis as it firms up and marking segments
/// `completed` once it will not revise them. That is the piece Speaches
/// cannot do: its `/v1/realtime` endpoint has excellent server-side VAD, but
/// its transcriber only starts once the input buffer is committed, so the
/// transcript still lands after the speaker stops. Verified against the
/// running container — the realtime path calls its own
/// `/v1/audio/transcriptions` on commit and emits no interim deltas.
///
/// The protocol, in full:
///  - connect, then send one JSON options frame carrying a client `uid`;
///  - wait for `{"message": "SERVER_READY"}` before sending audio, because
///    anything sent earlier is dropped while the model loads;
///  - stream raw **float32 mono 16 kHz** binary frames;
///  - read `{"segments": [{start, end, text, completed}]}` — the last N
///    segments, resent whole each time, not a delta;
///  - stop sending, and keep reading: the server re-cuts the audio it holds
///    and finalises the tail a second or so later. (There is an
///    `END_OF_AUDIO` sentinel, sent as *bytes*, but it closes the session
///    before that last window is transcribed — see [finish].)
class WhisperLiveClient {
  WhisperLiveClient({
    String? baseUrl,
    String? backupUrl,
    String? model,
    String? cfAccessClientId,
    String? cfAccessClientSecret,
  })  : endpoint = RemoteEndpoint(
          primary: baseUrl,
          backup: backupUrl,
          cfAccessClientId: cfAccessClientId,
          cfAccessClientSecret: cfAccessClientSecret,
        ),
        model = model ?? defaultModel;

  /// Same primary/backup/sticky/Access arrangement as every other
  /// self-hosted service the app talks to, so live transcription works off
  /// the LAN through the tunnel instead of silently degrading the moment you
  /// leave the house — the v4.2.0 lesson, applied to a new transport.
  final RemoteEndpoint endpoint;

  /// A faster-whisper model name or a CTranslate2 repo id. `small.en` is the
  /// default because streaming is a latency problem before it is an accuracy
  /// one: on a 3090 it keeps the hypothesis within about a word of the
  /// speaker, where large-v3 falls a sentence behind and never catches up.
  /// The final transcript can still be re-cut by a bigger model.
  static const String defaultModel = 'small.en';

  String model;

  /// Handshake fields that are not worth a setting but are worth not leaving
  /// at the server's defaults.
  ///
  /// `use_vad` keeps Whisper off pure room noise, which is what produces
  /// "Thank you." out of a silent clip. `send_last_n_segments` bounds how
  /// much history is resent on every update. `same_output_threshold` is how
  /// many identical hypotheses in a row mark a segment finished — the
  /// server's default of 10 is a long wait at the end of a sentence.
  static const bool useVad = true;
  static const int segmentWindow = 6;
  static const int sameOutputThreshold = 4;

  /// How long to wait for the connection and the model to be ready. A cold
  /// faster-whisper load is seconds; a second turn is instant.
  static const Duration readyTimeout = Duration(seconds: 12);

  WebSocket? _socket;
  StreamSubscription? _messages;
  Completer<bool>? _ready;
  final _uuid = const Uuid();
  String _uid = '';

  final StreamController<LiveTranscript> _transcripts =
      StreamController<LiveTranscript>.broadcast();

  /// Hypotheses as they firm up. Fires on every server update, so a listener
  /// can paint each new word as it is recognised.
  Stream<LiveTranscript> get transcripts => _transcripts.stream;

  final StreamController<String> _errors = StreamController<String>.broadcast();
  Stream<String> get errors => _errors.stream;

  /// Completed segment text, in order, keyed by start time so a resent
  /// segment updates in place instead of being appended twice.
  final Map<double, String> _completed = {};
  String _tail = '';

  LiveTranscript get current {
    final entries = _completed.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final parts = [
      for (final e in entries) e.value.trim(),
      if (_tail.trim().isNotEmpty) _tail.trim(),
    ];
    // Whisper fills the silence after a sentence with a word of its own —
    // " end.", " you" — which arrives as its own segment, sometimes marked
    // completed. Dropped only when it trails real text: on its own it is the
    // phantom check's job, which knows how much speech there was.
    final tailIsLive = _tail.trim().isNotEmpty;
    var keep = parts.length;
    while (keep > 1 && isFiller(parts[keep - 1])) {
      keep--;
    }
    final droppedTail = tailIsLive && keep < parts.length;
    final committedCount =
        tailIsLive && !droppedTail ? keep - 1 : keep;
    return LiveTranscript(
      committed: parts.take(committedCount).join(' ').trim(),
      tail: tailIsLive && !droppedTail ? parts[keep - 1] : '',
    );
  }

  /// Words Whisper produces from silence or room noise. Short on purpose:
  /// "yes", "no", "stop" and "thanks" are real answers.
  static const Set<String> _fillers = {
    'end',
    'the end',
    'you',
    'thank you',
    'thanks for watching',
    'bye',
    'blank audio',
    'silence',
    'music',
  };

  /// Whether [text] is one of the stock things Whisper says to no one.
  static bool isFiller(String text) {
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z' ]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return normalized.isEmpty || _fillers.contains(normalized);
  }

  bool get isConfigured => endpoint.isConfigured;
  bool get isConnected => _socket != null;

  /// True when the live server answered at its remote address, which the UI
  /// shows as "connected remotely".
  bool get isOnBackup => endpoint.isOnBackup;

  /// Opens a session and waits until the server says it is ready to receive
  /// audio. Returns false with a reason on [errors] if it never got there.
  Future<bool> connect({String? languageCode}) async {
    if (isConnected) return true;
    if (!isConfigured) {
      _errors.add('No live transcription server address is set.');
      return false;
    }

    try {
      return await endpoint.withFailover((base) async {
        final ready = Completer<bool>();
        _ready = ready;
        _uid = _uuid.v4();
        _completed.clear();
        _tail = '';

        final socket = await WebSocket.connect(
          websocketUrl(base).toString(),
          headers: endpoint.headersFor(base),
        ).timeout(const Duration(seconds: 6));
        _socket = socket;
        _messages = socket.listen(
          _onMessage,
          onDone: _onDone,
          onError: (Object e) => _errors.add('Live transcription dropped: $e'),
        );

        socket.add(json.encode({
          'uid': _uid,
          'model': model.trim().isEmpty ? defaultModel : model.trim(),
          'task': 'transcribe',
          // Null, not the empty string: WhisperLive reads null as "detect it"
          // and an unknown code as an error.
          'language': (languageCode?.trim().isNotEmpty ?? false)
              ? languageCode!.trim()
              : null,
          'use_vad': useVad,
          'send_last_n_segments': segmentWindow,
          'same_output_threshold': sameOutputThreshold,
          'clip_audio': false,
          'no_speech_thresh': 0.45,
        }));

        final ok = await ready.future.timeout(
          readyTimeout,
          onTimeout: () => false,
        );
        if (!ok) {
          // Failover only moves on for *transport* failures, so a server that
          // accepted the socket and then never got ready has to be turned
          // into one for the backup address to be tried at all.
          await _teardown();
          throw const SocketException('Live transcription server never became ready.');
        }
        return true;
      });
    } on TimeoutException {
      _errors.add('The live transcription server did not answer in time.');
      return false;
    } on SocketException catch (e) {
      _errors.add('Could not reach the live transcription server: ${e.message}');
      return false;
    } on WebSocketException catch (e) {
      _errors.add('Could not open a live transcription session: ${e.message}');
      return false;
    } catch (e) {
      _errors.add('Live transcription failed to start: $e');
      return false;
    }
  }

  /// The path a fronted WhisperLive sits on when it shares a hostname with
  /// the rest of the speech stack.
  ///
  /// Sharing is the sane arrangement once the server is reachable remotely:
  /// one tunnel hostname, one Access app, one service token, and nothing new
  /// to type into Settings. WhisperLive accepts a WebSocket on *any* path —
  /// it never looks at it — so a reverse proxy in front can route `/live`
  /// here and everything else to the transcription/speech API without
  /// rewriting anything.
  static const String sharedPath = '/live';

  /// The live address implied by the address of the rest of the speech stack.
  ///
  /// Empty in, empty out, so an unconfigured speech server doesn't produce a
  /// confident-looking live address pointing at nothing.
  static String sharedWith(String speechBase) {
    final base = RemoteEndpoint.normalize(speechBase);
    if (base.isEmpty) return '';
    return base.endsWith(sharedPath) ? base : '$base$sharedPath';
  }

  /// `http(s)://host:9090` in settings, `ws(s)://host:9090` on the wire.
  /// Written as an http address everywhere else in the app, so the one place
  /// that cares about the scheme converts it rather than asking the user to.
  ///
  /// Any path on the address is kept: that is what lets this live behind the
  /// same hostname as the transcription API, on [sharedPath].
  static Uri websocketUrl(String base) {
    final normalized = RemoteEndpoint.normalize(base);
    final uri = Uri.parse(normalized);
    return uri.replace(scheme: uri.scheme == 'https' ? 'wss' : 'ws');
  }

  /// Sends one captured frame. Cheap enough to call per 100 ms of audio;
  /// float32 at 16 kHz is 64 KB/s on the uplink, which is why this is a
  /// Wi-Fi-first feature and the file path stays for metered connections.
  void send(Float32List frame) {
    final socket = _socket;
    if (socket == null || frame.isEmpty) return;
    if (socket.readyState != WebSocket.open) return;
    socket.add(Float32List.fromList(frame).buffer.asUint8List());
  }

  /// Ends the turn and returns the final transcript.
  ///
  /// Deliberately does **not** send `END_OF_AUDIO`. The sentinel makes the
  /// server tear the session down immediately, and measured against the
  /// running container that costs the last window of audio — the closing
  /// words of the sentence are simply never transcribed. Stopping the frames
  /// and waiting is strictly better: the server keeps re-cutting the audio it
  /// already has, the tail arrives about a second later, and it marks the
  /// segment `completed` a second after that.
  ///
  /// So: resolve once the hypothesis stops changing for [settle], and give up
  /// after [grace] with whatever is on hand. Never returns less than it had
  /// already heard — a slow final window is not a reason to lose the sentence
  /// the user just spoke.
  Future<LiveTranscript> finish({
    Duration settle = const Duration(milliseconds: 400),
    Duration grace = const Duration(milliseconds: 2500),
  }) async {
    final socket = _socket;
    if (socket == null) return current;

    // Changes, not messages: the server resends an unchanged hypothesis every
    // few hundred milliseconds, and counting those as activity meant this
    // always ran to [grace].
    var lastUpdate = DateTime.now();
    var lastText = current.text;
    final watch = _transcripts.stream.listen((t) {
      if (t.text == lastText) return;
      lastText = t.text;
      lastUpdate = DateTime.now();
    });
    try {
      final deadline = DateTime.now().add(grace);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (DateTime.now().difference(lastUpdate) > settle) break;
      }
    } catch (_) {
      // A socket that died on flush still leaves the hypothesis intact.
    } finally {
      await watch.cancel();
    }
    return current;
  }

  /// Ends the session. The socket is deliberately not kept open between
  /// turns: WhisperLive holds a model slot per connection, and a phone in a
  /// pocket holding one open is a slot nobody else can have.
  Future<void> close() => _teardown();

  Future<void> dispose() async {
    await _teardown();
    if (!_transcripts.isClosed) await _transcripts.close();
    if (!_errors.isClosed) await _errors.close();
  }

  Future<void> _teardown() async {
    await _messages?.cancel();
    _messages = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    _ready = null;
  }

  void _onDone() {
    _socket = null;
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete(false);
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    final Map<String, dynamic> event;
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) return;
      event = decoded;
    } catch (_) {
      return;
    }

    // Every server frame carries the uid of the session it belongs to.
    final uid = event['uid'];
    if (uid is String && _uid.isNotEmpty && uid != _uid) return;

    if (event['status'] == 'ERROR' || event['message'] == 'ERROR') {
      _errors.add('Live transcription server: ${event['message'] ?? 'error'}');
      return;
    }

    switch (event['message']) {
      case 'SERVER_READY':
        _ready?.complete(true);
        return;
      case 'WAIT':
        // Every model slot is busy. Reported rather than waited out: the
        // estimate is in minutes, and a voice turn does not have minutes.
        final minutes = event['message_body'] ?? event['wait'] ?? '';
        _errors.add(
          'The live transcription server is full${minutes == '' ? '' : ' (about $minutes min)'}. '
          'Falling back to recording the whole turn.',
        );
        _ready?.complete(false);
        return;
      case 'DISCONNECT':
        _ready?.complete(false);
        unawaited(_teardown());
        return;
    }

    final segments = event['segments'];
    if (segments is! List) return;
    applySegments(segments);
    if (!_transcripts.isClosed) _transcripts.add(current);
  }

  /// Folds a resent segment window into [current].
  ///
  /// The server sends the last N segments every time, so this has to be
  /// idempotent: a `completed` segment overwrites its own slot by start time,
  /// and only the trailing incomplete one becomes the revisable tail.
  void applySegments(List<dynamic> segments) {
    var tail = '';
    for (final entry in segments) {
      if (entry is! Map) continue;
      final text = (entry['text'] ?? '').toString();
      if (text.trim().isEmpty) continue;
      final start = double.tryParse((entry['start'] ?? '').toString()) ?? 0.0;
      final done = entry['completed'] == true;
      if (done) {
        _completed[start] = text;
      } else {
        tail = text;
      }
    }
    _tail = tail;
  }
}
