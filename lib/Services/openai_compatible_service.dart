import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Services/chat_service.dart';
import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

/// Everything shared by backends that speak the OpenAI Chat Completions
/// protocol: request shaping, SSE parsing, streamed tool-call reassembly, and
/// message/tool-result encoding.
///
/// Subclasses supply the endpoint, the auth headers, and how to turn the
/// provider's `/v1/models` payload into [OllamaModel]s — which is where OpenAI
/// and OpenRouter genuinely differ.
abstract class OpenAiCompatibleService extends ChatService {
  String _apiKey;
  String _baseUrl;

  /// Hard kill switch. When false the provider is fully dead — no models
  /// listed, no routing, cannot be selected — regardless of whether a key is
  /// set.
  bool enabled;

  OpenAiCompatibleService({
    String? apiKey,
    String? baseUrl,
    this.enabled = false,
  })  : _apiKey = apiKey ?? '',
        _baseUrl = baseUrl ?? '';

  /// Short bracketed tag used in user-facing error text, e.g. `[OpenRouter]`.
  String get logTag;

  /// Base URL to fall back to when the user hasn't overridden it.
  String get defaultBaseUrl;

  set apiKey(String? value) => _apiKey = value ?? '';
  String get apiKey => _apiKey;

  set baseUrl(String? value) =>
      _baseUrl = (value == null || value.isEmpty) ? defaultBaseUrl : value;
  String get baseUrl => _baseUrl.isEmpty ? defaultBaseUrl : _baseUrl;

  @override
  bool get isConfigured => enabled && _apiKey.isNotEmpty;

  /// Extra headers on top of auth + content type. Subclasses add their own.
  Map<String, String> get extraHeaders => const {};

  Map<String, String> get headers => {
        'Authorization': 'Bearer $_apiKey',
        'content-type': 'application/json',
        ...extraHeaders,
      };

  /// Turns a `/v1/models` body into models. Called only on HTTP 200.
  List<OllamaModel> parseModels(Map<String, dynamic> body);

  @override
  Future<List<OllamaModel>> listModels() async {
    if (!isConfigured) {
      throw OllamaException('$logTag API key not set.');
    }

    return _guard(() async {
      final response = await HorizonHttp.client
          .get(Uri.parse('$baseUrl/v1/models'), headers: headers)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        return parseModels(
          json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
        );
      }

      throw OllamaException(
        '$logTag ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}',
      );
    });
  }

  @override
  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
    List<ToolDefinition> tools = const [],
  }) async* {
    if (!isConfigured) {
      throw OllamaException('$logTag API key not set.');
    }

    final body = <String, dynamic>{
      'model': chat.model,
      'messages': await encodeMessages(messages, chat.systemPrompt),
      'stream': true,
    };
    if (acceptsTemperature(chat.model)) {
      body['temperature'] = chat.options.temperature;
    }
    if (chat.options.maxTokens > 0) {
      body['max_completion_tokens'] = chat.options.maxTokens;
    }
    if (tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toOpenAiJson()).toList();
      body['tool_choice'] = 'auto';
    }
    decorateRequestBody(body, chat);
    final encodedBody = json.encode(body);

    try {
      // Retried once on connection-level failures before any bytes arrive;
      // the request is rebuilt per attempt so a retry is always safe.
      final response = await HorizonHttp.sendWithRetry(
        () {
          final request =
              http.Request('POST', Uri.parse('$baseUrl/v1/chat/completions'));
          request.headers.addAll(headers);
          request.body = encodedBody;
          return request;
        },
        timeout: const Duration(seconds: 60),
      );

      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw OllamaException(
          '$logTag ${HttpErrorFormatter.formatHttpError(response.statusCode, body: text)}',
        );
      }

      // Stall guard: reasoning gaps can run long, but a dead connection
      // shouldn't hang "Generating" forever.
      yield* parseSse(
        response.stream.stallGuard(const Duration(seconds: 180), logTag),
        chat.model,
      );
    } on TimeoutException catch (e) {
      throw OllamaException('$logTag ${HttpErrorFormatter.formatException(e)}');
    } on SocketException catch (e) {
      throw OllamaException('$logTag ${HttpErrorFormatter.formatException(e)}');
    } on http.ClientException catch (e) {
      throw OllamaException('$logTag ${HttpErrorFormatter.formatException(e)}');
    }
  }

  /// Hook for provider-specific request fields. Default does nothing.
  void decorateRequestBody(Map<String, dynamic> body, OllamaChat chat) {}

  /// Parses the SSE stream, emitting text deltas as they arrive and — once the
  /// turn ends — a final message carrying any reassembled tool calls.
  ///
  /// Tool calls arrive in fragments: the first delta for an index carries the
  /// id and function name, then the JSON arguments dribble in across many
  /// deltas as raw string pieces. They're accumulated per index and only
  /// decoded at the end, because no intermediate fragment is valid JSON.
  Stream<OllamaMessage> parseSse(Stream<List<int>> stream, String model) async* {
    final partials = <int, _PartialToolCall>{};
    String buffer = '';
    var emittedDone = false;

    OllamaMessage finalMessage() => OllamaMessage(
          '',
          role: OllamaMessageRole.assistant,
          model: model,
          done: true,
          toolCalls: _materialize(partials),
        );

    await for (final chunk in stream.transform(utf8.decoder)) {
      buffer += chunk;
      while (true) {
        final newlineIdx = buffer.indexOf('\n');
        if (newlineIdx == -1) break;
        final line = buffer.substring(0, newlineIdx).trimRight();
        buffer = buffer.substring(newlineIdx + 1);

        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') {
          emittedDone = true;
          yield finalMessage();
          return;
        }

        try {
          final event = json.decode(payload) as Map<String, dynamic>;

          // OpenRouter (and some proxies) report mid-stream failures as an
          // error object on an otherwise-200 SSE stream.
          final error = event['error'];
          if (error != null) {
            throw OllamaException(
              '$logTag ${HttpErrorFormatter.formatHttpError(200, body: json.encode(event))}',
            );
          }

          final choices = event['choices'] as List<dynamic>?;
          if (choices == null || choices.isEmpty) continue;
          final choice = choices.first as Map<String, dynamic>;
          final delta = choice['delta'] as Map<String, dynamic>?;

          final text = delta?['content'];
          if (text is String && text.isNotEmpty) {
            yield OllamaMessage(
              text,
              role: OllamaMessageRole.assistant,
              model: model,
            );
          }

          final deltaToolCalls = delta?['tool_calls'];
          if (deltaToolCalls is List) {
            for (final raw in deltaToolCalls) {
              if (raw is! Map) continue;
              final index = (raw['index'] as num?)?.toInt() ?? 0;
              final partial =
                  partials.putIfAbsent(index, () => _PartialToolCall());
              final id = raw['id'];
              if (id is String && id.isNotEmpty) partial.id = id;
              final function = raw['function'];
              if (function is Map) {
                final name = function['name'];
                if (name is String && name.isNotEmpty) partial.name = name;
                final args = function['arguments'];
                if (args is String) partial.arguments.write(args);
              }
            }
          }

          // Some gateways close without a [DONE] sentinel; finish_reason is
          // the other reliable end-of-turn marker.
          final finishReason = choice['finish_reason'];
          if (finishReason is String && finishReason.isNotEmpty) {
            emittedDone = true;
            yield finalMessage();
            return;
          }
        } on FormatException {
          continue;
        }
      }
    }

    // Stream ended with neither [DONE] nor a finish_reason — still deliver
    // any tool calls we reassembled, or the turn would silently do nothing.
    if (!emittedDone) yield finalMessage();
  }

  static List<ToolCall>? _materialize(Map<int, _PartialToolCall> partials) {
    if (partials.isEmpty) return null;
    final indices = partials.keys.toList()..sort();
    final calls = <ToolCall>[];
    for (final index in indices) {
      final partial = partials[index]!;
      if (partial.name.isEmpty) continue;
      calls.add(ToolCall(
        id: partial.id.isEmpty ? 'call_${Uuid().v4()}' : partial.id,
        name: partial.name,
        arguments: ToolCall.parseArguments(partial.arguments.toString()),
      ));
    }
    return calls.isEmpty ? null : calls;
  }

  /// Encodes the transcript. Tool calls ride on the assistant turn and results
  /// come back as `role: "tool"` keyed by `tool_call_id`.
  Future<List<Map<String, dynamic>>> encodeMessages(
    List<OllamaMessage> messages,
    String? systemPrompt,
  ) async {
    final out = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      out.add({'role': 'system', 'content': systemPrompt});
    }

    for (final m in messages) {
      if (m.role == OllamaMessageRole.system) continue;

      if (m.role == OllamaMessageRole.tool) {
        out.add({
          'role': 'tool',
          'tool_call_id': m.toolCallId ?? m.toolName ?? 'call_0',
          'content': m.content,
        });
        continue;
      }

      if (m.role == OllamaMessageRole.assistant && m.hasToolCalls) {
        out.add({
          'role': 'assistant',
          // The API requires the key even when the turn was tool-calls only.
          'content': m.content.isEmpty ? null : m.content,
          'tool_calls': m.toolCalls!
              .map((c) => {
                    'id': c.id,
                    'type': 'function',
                    'function': {
                      'name': c.name,
                      'arguments': json.encode(c.arguments),
                    },
                  })
              .toList(),
        });
        continue;
      }

      final images = await _encodeImagesBase64(m);
      if (images.isEmpty) {
        out.add({'role': roleName(m.role), 'content': m.promptContent});
      } else {
        final content = <Map<String, dynamic>>[];
        if (m.promptContent.isNotEmpty) {
          content.add({'type': 'text', 'text': m.promptContent});
        }
        for (final b64 in images) {
          content.add({
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,$b64'},
          });
        }
        out.add({'role': roleName(m.role), 'content': content});
      }
    }
    return out;
  }

  static Future<List<String>> _encodeImagesBase64(OllamaMessage m) async {
    if (m.images == null || m.images!.isEmpty) return const [];
    final encoded = <String>[];
    for (final file in m.images!) {
      try {
        final bytes = await file.readAsBytes();
        encoded.add(base64Encode(bytes));
      } catch (_) {
        continue;
      }
    }
    return encoded;
  }

  static String roleName(OllamaMessageRole role) {
    switch (role) {
      case OllamaMessageRole.user:
        return 'user';
      case OllamaMessageRole.assistant:
        return 'assistant';
      case OllamaMessageRole.system:
        return 'system';
      case OllamaMessageRole.tool:
        return 'tool';
    }
  }

  /// Whether `temperature` may be sent for [model]. Reasoning models reject it.
  bool acceptsTemperature(String model) => true;

  /// Wraps a call so every transport failure surfaces as a tagged
  /// OllamaException with real detail instead of a raw platform error.
  Future<T> _guard<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on TimeoutException catch (e) {
      throw OllamaException('$logTag ${HttpErrorFormatter.formatException(e)}');
    } on SocketException catch (e) {
      throw OllamaException('$logTag ${HttpErrorFormatter.formatException(e)}');
    } on http.ClientException catch (e) {
      throw OllamaException('$logTag ${HttpErrorFormatter.formatException(e)}');
    }
  }
}

class _PartialToolCall {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
