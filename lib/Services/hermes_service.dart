import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:horizon/Constants/generate_title_constants.dart';
import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/model_capabilities.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Services/chat_service.dart';
import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Utils/http_error_formatter.dart';
import 'package:horizon/Utils/remote_endpoint.dart';

/// A Hermes agent running on one of your own machines, driven through its API
/// server's Runs endpoints.
///
/// Not another model: Hermes runs its own tools (terminal, files, web, memory,
/// skills) on the machine it lives on and streams back what it's doing. So
/// this provider declares no Horizon tools, and instead of resending the
/// transcript every turn it binds each Horizon chat to a Hermes session that
/// keeps the history — tool calls and results included — server-side.
///
/// Uses `/v1/runs` rather than `/v1/chat/completions` because only runs can
/// pause on an approval: a risky command parks the run in
/// `waiting_for_approval`, an `approval.request` event goes out on [events],
/// and the run resumes once [respondToApproval] posts the decision.
class HermesService extends ChatService {
  HermesService({
    String? baseUrl,
    String? backupUrl,
    String? apiKey,
    String? cfAccessClientId,
    String? cfAccessClientSecret,
    this.enabled = false,
  })  : apiKey = apiKey ?? '',
        endpoint = RemoteEndpoint(
          primary: baseUrl,
          backup: backupUrl,
          cfAccessClientId: cfAccessClientId,
          cfAccessClientSecret: cfAccessClientSecret,
        );

  static const String id = 'hermes';
  static const String _logTag = '[Hermes]';

  /// Hive key mapping Horizon chat ids to the Hermes session each one talks
  /// to and how many user turns that session has seen.
  static const String sessionsKey = 'hermes_sessions';

  final RemoteEndpoint endpoint;
  String apiKey;
  bool enabled;

  /// The run each chat is waiting on, so Stop can reach it. Horizon's own
  /// cancel only lands when the next chunk arrives, and a run parked on an
  /// approval or a long command sends no chunks.
  final Map<String, (String, String)> _activeRuns = {};

  final StreamController<HermesEvent> _events =
      StreamController<HermesEvent>.broadcast();

  /// What the agent is doing while a turn runs: tool starts and finishes,
  /// approval requests, and the run ending. Text arrives on [chatStream].
  Stream<HermesEvent> get events => _events.stream;

  @override
  String get providerId => id;

  @override
  bool get isConfigured =>
      enabled && endpoint.isConfigured && apiKey.trim().isNotEmpty;

  /// Hermes brings its own tools; Horizon's are never declared to it.
  @override
  bool get supportsTools => false;

  Map<String, String> _headers(String base) => {
        ...endpoint.headersFor(base, bearerToken: apiKey),
        'content-type': 'application/json',
      };

  @override
  Future<List<OllamaModel>> listModels() async {
    if (!isConfigured) throw OllamaException('$_logTag Not configured.');
    final response = await _guard(() => endpoint.withFailover((base) =>
        HorizonHttp.client
            .get(RemoteEndpoint.resolve(base, '/v1/models'), headers: _headers(base))
            .timeout(const Duration(seconds: 15))));
    final body = utf8.decode(response.bodyBytes);
    if (response.statusCode != 200) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatHttpError(response.statusCode, body: body)}');
    }
    final Map<String, dynamic> decoded;
    try {
      decoded = json.decode(body) as Map<String, dynamic>;
    } on FormatException {
      throw OllamaException('$_logTag ${endpoint.describeAccessBlock(body, endpoint.candidates().first) ?? 'Unreadable model list.'}');
    }
    return [
      for (final entry in (decoded['data'] as List<dynamic>? ?? const []))
        if (entry is Map && (entry['id'] ?? '').toString().isNotEmpty)
          OllamaModel.cloud(
            provider: id,
            id: entry['id'].toString(),
            parameterSize: 'Agent · runs tools on its own machine',
            capabilities: const ModelCapabilities(completion: true),
          ),
    ];
  }

  @override
  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
    List<ToolDefinition> tools = const [],
  }) async* {
    if (!isConfigured) throw OllamaException('$_logTag Not configured.');
    final lastUser = messages.lastIndexWhere((m) => m.role == OllamaMessageRole.user);
    if (lastUser == -1) return;

    final session = _sessionFor(chat.id, messages);
    final body = <String, dynamic>{
      'input': _inputText(messages[lastUser]),
      'session_id': session.id,
      if (chat.systemPrompt != null && chat.systemPrompt!.trim().isNotEmpty)
        'instructions': chat.systemPrompt,
      if (session.history != null) 'conversation_history': session.history,
    };

    // The run is created once; a retried POST with the same key returns the
    // same run instead of starting the turn twice.
    final idempotencyKey = 'horizon-${const Uuid().v4()}';
    late final String base;
    late final String runId;
    final created = await _guard(() => endpoint.withFailover((candidate) async {
          final r = await HorizonHttp.client
              .post(
                RemoteEndpoint.resolve(candidate, '/v1/runs'),
                headers: {..._headers(candidate), 'Idempotency-Key': idempotencyKey},
                body: json.encode(body),
              )
              .timeout(const Duration(seconds: 30));
          base = candidate;
          return r;
        }));
    final createdBody = utf8.decode(created.bodyBytes);
    if (created.statusCode != 202 && created.statusCode != 200) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatHttpError(created.statusCode, body: createdBody)}');
    }
    try {
      runId = (json.decode(createdBody) as Map<String, dynamic>)['run_id'] as String;
    } catch (_) {
      throw OllamaException('$_logTag ${endpoint.describeAccessBlock(createdBody, base) ?? 'Run was not created.'}');
    }

    var finished = false;
    var streamedText = false;
    _activeRuns[chat.id] = (base, runId);
    try {
      final request = http.Request('GET', RemoteEndpoint.resolve(base, '/v1/runs/$runId/events'))
        ..headers.addAll(endpoint.headersFor(base, bearerToken: apiKey))
        ..headers['accept'] = 'text/event-stream';
      final response = await HorizonHttp.client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw OllamaException('$_logTag ${HttpErrorFormatter.formatHttpError(response.statusCode, body: text)}');
      }

      // Hermes sends a keepalive comment every 10 s, so a long tool call or a
      // pending approval never trips this; only a dead connection does.
      final lines = response.stream
          .stallGuard(const Duration(seconds: 120), _logTag)
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (!line.startsWith('data:')) continue; // event:, ids, `: keepalive`
        final Map<String, dynamic> event;
        try {
          event = json.decode(line.substring(5).trim()) as Map<String, dynamic>;
        } on FormatException {
          continue;
        }

        switch (event['event']) {
          case 'message.delta':
            final delta = event['delta'];
            if (delta is String && delta.isNotEmpty) {
              streamedText = true;
              yield _text(delta, chat);
            }
          case 'message.interim':
            final text = event['text'];
            if (event['already_streamed'] != true && text is String && text.trim().isNotEmpty) {
              streamedText = true;
              yield _text('$text\n\n', chat);
            }
          case 'tool.started':
            _events.add(HermesEvent.toolStarted(chat.id, runId,
                tool: '${event['tool'] ?? 'tool'}', preview: '${event['preview'] ?? ''}'));
          case 'tool.completed' || 'tool.failed':
            _events.add(HermesEvent.toolFinished(chat.id, runId,
                tool: '${event['tool'] ?? 'tool'}', failed: event['error'] == true || event['event'] == 'tool.failed'));
          case 'approval.request':
            _events.add(HermesEvent.approval(chat.id, HermesApproval.fromEvent(runId, event)));
          case 'approval.responded':
            _events.add(HermesEvent.approvalResolved(chat.id, runId));
          case 'run.completed':
            finished = true;
            session.commit();
            final output = event['output'];
            // A model that doesn't stream still produces an answer.
            if (!streamedText && output is String && output.isNotEmpty) yield _text(output, chat);
            return;
          case 'run.failed':
            finished = true;
            // The turn reached Hermes, so its session moved on even though
            // the answer didn't arrive.
            session.commit();
            throw OllamaException('$_logTag ${event['error'] ?? 'The run failed.'}');
          case 'run.cancelled' || 'run.interrupted':
            finished = true;
            session.commit();
            return;
        }
      }
      throw OllamaException('$_logTag The connection closed before the run finished.');
    } on TimeoutException catch (e) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatException(e)}');
    } on SocketException catch (e) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatException(e)}');
    } on http.ClientException catch (e) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatException(e)}');
    } finally {
      if (_activeRuns[chat.id]?.$2 == runId) _activeRuns.remove(chat.id);
      _events.add(HermesEvent.runEnded(chat.id, runId));
      // The listener cancelled (Stop) or the stream died: don't leave the
      // agent working — or parked on an approval — with nobody watching.
      if (!finished) unawaited(stop(base, runId));
    }
  }

  /// Titles come from the first message rather than a model call: every
  /// Hermes turn carries the agent's whole system prompt and toolset, which is
  /// a lot to spend on four words.
  @override
  Stream<OllamaMessage> generateStream(String prompt, {required OllamaChat chat}) async* {
    final text = prompt.replaceFirst(GenerateTitleConstants.prompt, '').trim();
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(6).join(' ');
    if (words.isNotEmpty) yield _text(words, chat);
  }

  /// Resolves a pending approval. [choice] is one of [HermesApproval.choices].
  Future<void> respondToApproval(HermesApproval approval, String choice) async {
    final response = await _guard(() => endpoint.withFailover((base) => HorizonHttp.client
        .post(
          RemoteEndpoint.resolve(base, '/v1/runs/${approval.runId}/approval'),
          headers: _headers(base),
          body: json.encode({
            'choice': choice,
            if (approval.requestId != null) 'request_id': approval.requestId,
          }),
        )
        .timeout(const Duration(seconds: 15))));
    if (response.statusCode != 200) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}');
    }
  }

  /// Stops whatever run [chatId] is waiting on. The run then ends with
  /// `run.cancelled`, which closes [chatStream] normally.
  Future<void> cancelChat(String chatId) async {
    final active = _activeRuns[chatId];
    if (active != null) await stop(active.$1, active.$2);
  }

  Future<void> stop(String base, String runId) async {
    try {
      await HorizonHttp.client
          .post(RemoteEndpoint.resolve(base, '/v1/runs/$runId/stop'), headers: _headers(base))
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // Best effort: the run also ends on its own.
    }
  }

  OllamaMessage _text(String text, OllamaChat chat) =>
      OllamaMessage(text, role: OllamaMessageRole.assistant, model: chat.model);

  /// The run API takes text. Attachments travel as their extracted text, as
  /// for every other provider; images can't be sent this way yet, so say so
  /// instead of dropping them silently.
  static String _inputText(OllamaMessage m) {
    final images = m.images?.length ?? 0;
    if (images == 0) return m.promptContent;
    return '${m.promptContent}\n\n[$images image${images == 1 ? '' : 's'} attached in Horizon — not sent to the agent]';
  }

  /// Picks the Hermes session for this send.
  ///
  /// Normally the chat's existing session, which already holds every earlier
  /// turn — so only the new message is sent. But Horizon's transcript can
  /// diverge from it: regenerating, editing or deleting messages rewinds
  /// Horizon, and an older chat switched onto Hermes has history Hermes never
  /// saw. Both show up as the user-turn count not lining up, and both are
  /// answered the same way: a fresh session seeded with Horizon's transcript.
  _HermesSession _sessionFor(String chatId, List<OllamaMessage> messages) {
    final box = Hive.box('settings');
    final all = Map<String, dynamic>.from((box.get(sessionsKey) as Map?) ?? const {});
    final userTurns = messages.where((m) => m.role == OllamaMessageRole.user).length;
    final stored = all[chatId];

    void save(String sessionId) {
      all[chatId] = {'id': sessionId, 'turns': userTurns};
      box.put(sessionsKey, all);
    }

    if (stored is Map && stored['id'] is String && stored['turns'] == userTurns - 1) {
      return _HermesSession(stored['id'] as String, null, () => save(stored['id'] as String));
    }

    final sessionId = 'horizon-$chatId-${const Uuid().v4().substring(0, 8)}';
    final lastUser = messages.lastIndexWhere((m) => m.role == OllamaMessageRole.user);
    final history = [
      for (final m in messages.take(lastUser))
        if ((m.role == OllamaMessageRole.user || m.role == OllamaMessageRole.assistant) &&
            m.content.trim().isNotEmpty)
          {'role': m.role.name, 'content': m.role == OllamaMessageRole.user ? m.promptContent : m.content},
    ];
    return _HermesSession(sessionId, history.isEmpty ? null : history, () => save(sessionId));
  }

  Future<http.Response> _guard(Future<http.Response> Function() op) async {
    try {
      return await op();
    } on StateError catch (e) {
      throw OllamaException('$_logTag ${e.message}');
    } on TimeoutException catch (e) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatException(e)}');
    } on SocketException catch (e) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatException(e)}');
    } on http.ClientException catch (e) {
      throw OllamaException('$_logTag ${HttpErrorFormatter.formatException(e)}');
    }
  }
}

class _HermesSession {
  final String id;
  final List<Map<String, String>>? history;

  /// Records that this session has now seen the current turn. Only called
  /// once Hermes took the turn, so a send that never arrived is retried on
  /// the same terms.
  final void Function() commit;

  _HermesSession(this.id, this.history, this.commit);
}

/// A command Hermes won't run without a yes.
class HermesApproval {
  final String runId;
  final String? requestId;

  /// The flagged command, already redacted by Hermes.
  final String command;

  /// Why it was flagged ("delete in root path", …).
  final String description;

  /// What may be sent back: some of `once`, `session`, `always`, `deny`.
  final List<String> choices;

  const HermesApproval({
    required this.runId,
    required this.requestId,
    required this.command,
    required this.description,
    required this.choices,
  });

  factory HermesApproval.fromEvent(String runId, Map<String, dynamic> event) => HermesApproval(
        runId: runId,
        requestId: event['request_id'] as String?,
        command: '${event['command'] ?? event['tool'] ?? ''}',
        description: '${event['description'] ?? event['pattern_key'] ?? 'Needs your approval'}',
        choices: [
          for (final c in (event['choices'] as List<dynamic>? ?? const ['once', 'deny'])) c.toString(),
        ],
      );
}

enum HermesEventType { toolStarted, toolFinished, approval, approvalResolved, runEnded }

class HermesEvent {
  final HermesEventType type;
  final String chatId;
  final String runId;
  final String? tool;
  final String? preview;
  final bool failed;
  final HermesApproval? approval;

  const HermesEvent._(this.type, this.chatId, this.runId,
      {this.tool, this.preview, this.failed = false, this.approval});

  factory HermesEvent.toolStarted(String chatId, String runId, {required String tool, required String preview}) =>
      HermesEvent._(HermesEventType.toolStarted, chatId, runId, tool: tool, preview: preview);

  factory HermesEvent.toolFinished(String chatId, String runId, {required String tool, required bool failed}) =>
      HermesEvent._(HermesEventType.toolFinished, chatId, runId, tool: tool, failed: failed);

  factory HermesEvent.approval(String chatId, HermesApproval approval) =>
      HermesEvent._(HermesEventType.approval, chatId, approval.runId, approval: approval);

  factory HermesEvent.approvalResolved(String chatId, String runId) =>
      HermesEvent._(HermesEventType.approvalResolved, chatId, runId);

  factory HermesEvent.runEnded(String chatId, String runId) =>
      HermesEvent._(HermesEventType.runEnded, chatId, runId);

  /// The activity line while a tool runs: "terminal: ls -la ~/Downloads".
  String get activityLabel {
    final p = (preview ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (p.isEmpty) return 'Running $tool…';
    return '$tool: ${p.length > 70 ? '${p.substring(0, 70)}…' : p}';
  }
}
