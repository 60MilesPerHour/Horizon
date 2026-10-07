import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Services/hermes_service.dart';

/// A stand-in Hermes API server: records each run request and answers the
/// events stream with whatever [script] says for that run.
class _FakeHermes {
  late final HttpServer server;
  final runBodies = <Map<String, dynamic>>[];
  final approvals = <Map<String, dynamic>>[];
  final stopped = <String>[];
  List<Map<String, dynamic>> Function(int run) script = (_) => [];

  /// Completes the events stream of a run that should hang (to test Stop).
  Completer<void>? hang;

  String get base => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      if (req.headers.value('authorization') != 'Bearer k') {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      if (req.method == 'POST' && path == '/v1/runs') {
        runBodies.add(json.decode(await utf8.decodeStream(req)) as Map<String, dynamic>);
        req.response
          ..statusCode = 202
          ..write(json.encode({'run_id': 'run_${runBodies.length}', 'status': 'started'}));
        await req.response.close();
      } else if (req.method == 'GET' && path.endsWith('/events')) {
        final run = int.parse(path.split('/')[3].substring(4));
        req.response.headers.contentType = ContentType('text', 'event-stream');
        req.response.bufferOutput = false;
        req.response.write(': keepalive\n\n');
        for (final e in script(run)) {
          req.response.write('event: ${e['event']}\ndata: ${json.encode({...e, 'run_id': 'run_$run'})}\n\n');
          await req.response.flush();
        }
        if (hang != null) await hang!.future;
        await req.response.close();
      } else if (req.method == 'POST' && path.endsWith('/approval')) {
        approvals.add(json.decode(await utf8.decodeStream(req)) as Map<String, dynamic>);
        req.response.write(json.encode({'resolved': 1}));
        await req.response.close();
      } else if (req.method == 'POST' && path.endsWith('/stop')) {
        stopped.add(path.split('/')[3]);
        hang?.complete();
        req.response.write('{"status":"stopping"}');
        await req.response.close();
      } else if (path == '/v1/models') {
        req.response.write(json.encode({
          'data': [
            {'id': 'horizon-agent'}
          ]
        }));
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  }
}

List<Map<String, dynamic>> _reply(String text) => [
      for (final ch in text.split('')) {'event': 'message.delta', 'delta': ch},
      {'event': 'run.completed', 'output': text},
    ];

OllamaMessage _user(String t) => OllamaMessage(t, role: OllamaMessageRole.user);
OllamaMessage _assistant(String t) => OllamaMessage(t, role: OllamaMessageRole.assistant);

Future<String> _collect(Stream<OllamaMessage> s) async =>
    (await s.toList()).map((m) => m.content).join();

void main() {
  late _FakeHermes fake;
  late HermesService service;
  final chat = OllamaChat(id: 'chat-1', model: 'horizon-agent', provider: 'hermes');

  setUpAll(() async {
    Hive.init((await Directory.systemTemp.createTemp('hermes_test')).path);
    await Hive.openBox('settings');
  });

  setUp(() async {
    await Hive.box('settings').clear();
    fake = _FakeHermes();
    await fake.start();
    service = HermesService(baseUrl: fake.base, apiKey: 'k', enabled: true);
  });

  tearDown(() => fake.server.close(force: true));

  test('lists the agent as a model', () async {
    final models = await service.listModels();
    expect(models.single.name, 'horizon-agent');
    expect(models.single.provider, 'hermes');
  });

  test('streams deltas and continues the same session with only the new turn', () async {
    fake.script = (run) => _reply(run == 1 ? 'pong' : 'still pong');

    final first = [_user('ping')];
    expect(await _collect(service.chatStream(first, chat: chat)), 'pong');
    final second = [...first, _assistant('pong'), _user('again')];
    expect(await _collect(service.chatStream(second, chat: chat)), 'still pong');

    expect(fake.runBodies[0]['input'], 'ping');
    expect(fake.runBodies[0].containsKey('conversation_history'), isFalse);
    expect(fake.runBodies[1]['input'], 'again');
    expect(fake.runBodies[1]['session_id'], fake.runBodies[0]['session_id']);
    expect(fake.runBodies[1].containsKey('conversation_history'), isFalse,
        reason: 'Hermes already holds the earlier turns');
  });

  test('a rewound or pre-existing transcript starts a fresh, seeded session', () async {
    fake.script = (_) => _reply('ok');

    // An older chat switched onto Hermes: three turns Hermes never saw.
    final history = [_user('a'), _assistant('A'), _user('b'), _assistant('B'), _user('c')];
    await _collect(service.chatStream(history, chat: chat));
    expect(fake.runBodies[0]['conversation_history'], [
      {'role': 'user', 'content': 'a'},
      {'role': 'assistant', 'content': 'A'},
      {'role': 'user', 'content': 'b'},
      {'role': 'assistant', 'content': 'B'},
    ]);

    // Regenerate: same turn count as last time, so Hermes is ahead of Horizon.
    await _collect(service.chatStream(history, chat: chat));
    expect(fake.runBodies[1]['session_id'], isNot(fake.runBodies[0]['session_id']));
    expect(fake.runBodies[1]['conversation_history'], hasLength(4));
  });

  test('approval requests surface as events and answers reach the run', () async {
    fake.script = (_) => [
          {'event': 'tool.started', 'tool': 'terminal', 'preview': 'rm -rf /tmp/x'},
          {
            'event': 'approval.request',
            'request_id': 'req-1',
            'command': 'rm -rf /tmp/x',
            'description': 'delete in root path',
            'choices': ['once', 'session', 'always', 'deny'],
          },
          {'event': 'approval.responded', 'choice': 'deny'},
          {'event': 'tool.completed', 'tool': 'terminal', 'error': true},
          ..._reply('Blocked.'),
        ];

    final events = <HermesEvent>[];
    final sub = service.events.listen(events.add);
    await _collect(service.chatStream([_user('delete it')], chat: chat));
    await Future<void>.delayed(Duration.zero); // broadcast delivery is async
    await sub.cancel();

    final approval = events.firstWhere((e) => e.type == HermesEventType.approval).approval!;
    expect(approval.command, 'rm -rf /tmp/x');
    expect(approval.choices, ['once', 'session', 'always', 'deny']);
    expect(events.first.activityLabel, 'terminal: rm -rf /tmp/x');
    expect(events.map((e) => e.type), containsAllInOrder([
      HermesEventType.toolStarted,
      HermesEventType.approval,
      HermesEventType.approvalResolved,
      HermesEventType.toolFinished,
      HermesEventType.runEnded,
    ]));

    await service.respondToApproval(approval, 'deny');
    expect(fake.approvals.single, {'choice': 'deny', 'request_id': 'req-1'});
  });

  test('a failed run is an error, and the session still moves on', () async {
    fake.script = (run) => run == 1
        ? [
            {'event': 'run.failed', 'error': 'model unavailable'}
          ]
        : _reply('ok');

    final first = [_user('one')];
    await expectLater(
      _collect(service.chatStream(first, chat: chat)),
      throwsA(isA<OllamaException>().having((e) => e.message, 'message', contains('model unavailable'))),
    );
    // Retry drops the failed turn's empty reply; Hermes saw the turn, so the
    // next user message continues that session.
    await _collect(service.chatStream([...first, _user('two')], chat: chat));
    expect(fake.runBodies[1]['session_id'], fake.runBodies[0]['session_id']);
  });

  test('cancelChat stops a run that is sending nothing', () async {
    fake.hang = Completer<void>();
    fake.script = (_) => [
          {'event': 'tool.started', 'tool': 'terminal', 'preview': 'sleep 600'},
        ];
    final done = _collect(service.chatStream([_user('wait')], chat: chat))
        .then((_) => 'closed', onError: (Object e) => 'error: $e');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await service.cancelChat(chat.id);
    expect(fake.stopped, ['run_1']);
    expect(await done.timeout(const Duration(seconds: 5)), isNotNull);
  });

  test('titles come from the first message, not an agent turn', () async {
    final title = await _collect(service.generateStream(
        'Now generate a title for this message: check disk space on the media drive please',
        chat: chat));
    expect(title.split(' ').length, lessThanOrEqualTo(6));
    expect(fake.runBodies, isEmpty);
  });

  // Against the real agent. Set HERMES_URL and HERMES_KEY to run.
  final liveUrl = Platform.environment['HERMES_URL'];
  final liveKey = Platform.environment['HERMES_KEY'];
  test('live: two turns share a session and an approval can be denied', () async {
    final live = HermesService(baseUrl: liveUrl, apiKey: liveKey, enabled: true);
    final liveChat = OllamaChat(id: 'live-${DateTime.now().millisecondsSinceEpoch}', model: 'horizon-agent', provider: 'hermes');
    expect((await live.listModels()).single.provider, 'hermes');

    final t1 = [_user('Reply with just the word banana.')];
    expect((await _collect(live.chatStream(t1, chat: liveChat))).toLowerCase(), contains('banana'));
    final t2 = [...t1, _assistant('banana'), _user('Which fruit did you just say? One word.')];
    expect((await _collect(live.chatStream(t2, chat: liveChat))).toLowerCase(), contains('banana'));

    final dir = await Directory.systemTemp.createTemp('hermes_live');
    final sub = live.events.listen((e) {
      if (e.type == HermesEventType.approval) live.respondToApproval(e.approval!, 'deny');
    });
    final t3 = [...t2, _assistant('banana'), _user('Use the terminal to run exactly: rm -rf ${dir.path}')];
    await _collect(live.chatStream(t3, chat: liveChat));
    await sub.cancel();
    expect(dir.existsSync(), isTrue, reason: 'denied, so nothing was deleted');
    dir.deleteSync();
  }, skip: liveUrl == null || liveKey == null ? 'HERMES_URL / HERMES_KEY not set' : false,
      timeout: const Timeout(Duration(minutes: 5)));
}
