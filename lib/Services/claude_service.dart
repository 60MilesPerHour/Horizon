import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Models/model_capabilities.dart';
import 'package:horizon/Services/chat_service.dart';
import 'package:horizon/Utils/horizon_http.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

/// Anthropic Messages API client.
class ClaudeService extends ChatService {
  static const String _baseUrl = 'https://api.anthropic.com';
  static const String _apiVersion = '2023-06-01';

  String _apiKey;
  set apiKey(String? value) => _apiKey = value ?? '';
  String get apiKey => _apiKey;

  /// Hard kill switch. When false the provider is fully dead — no models
  /// listed, no routing, cannot be selected — regardless of whether a key is
  /// set. Defaults to off so the app is Ollama-only until explicitly enabled.
  bool enabled;

  ClaudeService({String? apiKey, this.enabled = false}) : _apiKey = apiKey ?? '';

  @override
  String get providerId => 'anthropic';

  @override
  bool get isConfigured => enabled && _apiKey.isNotEmpty;

  Map<String, String> get _headers => {
        'x-api-key': _apiKey,
        'anthropic-version': _apiVersion,
        'content-type': 'application/json',
      };

  @override
  Future<List<OllamaModel>> listModels() async {
    if (!isConfigured) {
      throw OllamaException('[Claude] API key not set.');
    }

    try {
      final response = await HorizonHttp.client
          .get(Uri.parse('$_baseUrl/v1/models'), headers: _headers)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final body = json.decode(response.body);
        final data = body['data'] as List<dynamic>? ?? [];
        return data.map((m) {
          final id = m['id'] as String;
          final displayName = m['display_name'] as String? ?? id;
          return OllamaModel.cloud(
            provider: providerId,
            id: id,
            parameterSize: displayName,
            capabilities: const ModelCapabilities(
              completion: true,
              vision: true,
              thinking: true,
            ),
          );
        }).toList();
      }

      throw OllamaException(
        '[Claude] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}',
      );
    } on TimeoutException catch (e) {
      throw OllamaException('[Claude] ${HttpErrorFormatter.formatException(e)}');
    } on SocketException catch (e) {
      throw OllamaException('[Claude] ${HttpErrorFormatter.formatException(e)}');
    } on http.ClientException catch (e) {
      throw OllamaException('[Claude] ${HttpErrorFormatter.formatException(e)}');
    }
  }

  @override
  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
    List<ToolDefinition> tools = const [],
  }) async* {
    if (!isConfigured) {
      throw OllamaException('[Claude] API key not set.');
    }

    final body = <String, dynamic>{
      'model': chat.model,
      'max_tokens': chat.options.maxTokens > 0 ? chat.options.maxTokens : 4096,
      'messages': await _encodeMessages(messages),
      'stream': true,
    };
    if (tools.isNotEmpty) {
      body['tools'] = tools.map((t) => t.toAnthropicJson()).toList();
    }
    // Claude 4.x extended-thinking models reject `temperature` outright.
    // Only forward it for models that accept it (legacy 3.x / non-thinking).
    if (_acceptsTemperature(chat.model)) {
      body['temperature'] = chat.options.temperature;
    }
    if (chat.systemPrompt != null && chat.systemPrompt!.isNotEmpty) {
      body['system'] = chat.systemPrompt;
    }
    final encodedBody = json.encode(body);

    try {
      // Retried once on connection-level failures before any bytes arrive;
      // the request is rebuilt per attempt so a retry is always safe.
      final response = await HorizonHttp.sendWithRetry(
        () {
          final request = http.Request('POST', Uri.parse('$_baseUrl/v1/messages'));
          request.headers.addAll(_headers);
          request.body = encodedBody;
          return request;
        },
        timeout: const Duration(seconds: 60),
      );

      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw OllamaException(
          '[Claude] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: text)}',
        );
      }

      // Stall guard: long enough for extended-thinking pauses, short enough
      // to surface a dead connection instead of hanging on "Generating".
      yield* _parseSse(
        response.stream.stallGuard(const Duration(seconds: 180), '[Claude]'),
        chat.model,
      );
    } on TimeoutException catch (e) {
      throw OllamaException('[Claude] ${HttpErrorFormatter.formatException(e)}');
    } on SocketException catch (e) {
      throw OllamaException('[Claude] ${HttpErrorFormatter.formatException(e)}');
    } on http.ClientException catch (e) {
      throw OllamaException('[Claude] ${HttpErrorFormatter.formatException(e)}');
    }
  }

  /// Parses Anthropic's SSE events.
  ///
  /// Tool use arrives as its own content block: `content_block_start` names the
  /// tool and gives it an id, then the arguments stream in as `input_json_delta`
  /// fragments of a JSON string, closed by `content_block_stop`. Nothing but
  /// the concatenation of those fragments is valid JSON, so they're buffered
  /// per block index and decoded at `message_stop`.
  Stream<OllamaMessage> _parseSse(Stream<List<int>> stream, String model) async* {
    final toolBlocks = <int, _PartialToolUse>{};
    String buffer = '';

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

        try {
          final event = json.decode(payload) as Map<String, dynamic>;
          final type = event['type'];

          if (type == 'content_block_start') {
            final block = event['content_block'] as Map<String, dynamic>?;
            if (block?['type'] == 'tool_use') {
              final index = (event['index'] as num?)?.toInt() ?? 0;
              toolBlocks[index] = _PartialToolUse(
                id: (block?['id'] ?? '').toString(),
                name: (block?['name'] ?? '').toString(),
              );
            }
          } else if (type == 'content_block_delta') {
            final delta = event['delta'] as Map<String, dynamic>?;
            final deltaType = delta?['type'];

            if (deltaType == 'input_json_delta') {
              final index = (event['index'] as num?)?.toInt() ?? 0;
              final fragment = delta?['partial_json'];
              if (fragment is String) {
                toolBlocks[index]?.arguments.write(fragment);
              }
            } else {
              final text = delta?['text'] as String?;
              if (text != null && text.isNotEmpty) {
                yield OllamaMessage(
                  text,
                  role: OllamaMessageRole.assistant,
                  model: model,
                );
              }
            }
          } else if (type == 'message_stop') {
            yield OllamaMessage(
              '',
              role: OllamaMessageRole.assistant,
              model: model,
              done: true,
              toolCalls: _materializeToolUses(toolBlocks),
            );
          } else if (type == 'error') {
            final err = event['error'] as Map<String, dynamic>?;
            throw OllamaException('[Claude] ${err?['message'] ?? 'stream error'}');
          }
        } on FormatException {
          continue;
        }
      }
    }
  }

  static List<ToolCall>? _materializeToolUses(Map<int, _PartialToolUse> blocks) {
    if (blocks.isEmpty) return null;
    final indices = blocks.keys.toList()..sort();
    final calls = <ToolCall>[];
    for (final index in indices) {
      final block = blocks[index]!;
      if (block.name.isEmpty) continue;
      calls.add(ToolCall(
        id: block.id,
        name: block.name,
        // A tool with no parameters streams no deltas at all, leaving an empty
        // buffer where the API contract implies `{}`.
        arguments: ToolCall.parseArguments(
          block.arguments.isEmpty ? '{}' : block.arguments.toString(),
        ),
      ));
    }
    return calls.isEmpty ? null : calls;
  }

  /// Encodes the transcript into Anthropic's blocks.
  ///
  /// Two constraints shape this: an assistant turn that called tools must
  /// replay its `tool_use` blocks verbatim, and **all** tool results for that
  /// turn must arrive as `tool_result` blocks inside a *single* user message.
  /// Horizon stores one message per tool result, so consecutive tool messages
  /// are coalesced here — emitting them separately is an immediate 400.
  Future<List<Map<String, dynamic>>> _encodeMessages(List<OllamaMessage> messages) async {
    final out = <Map<String, dynamic>>[];

    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == OllamaMessageRole.system) continue;

      if (m.role == OllamaMessageRole.tool) {
        final results = <Map<String, dynamic>>[];
        var j = i;
        while (j < messages.length &&
            messages[j].role == OllamaMessageRole.tool) {
          final toolMessage = messages[j];
          results.add({
            'type': 'tool_result',
            'tool_use_id': toolMessage.toolCallId ?? toolMessage.toolName ?? '',
            'content': toolMessage.content,
            if (toolMessage.toolFailed) 'is_error': true,
          });
          j++;
        }
        i = j - 1;
        out.add({'role': 'user', 'content': results});
        continue;
      }

      if (m.role == OllamaMessageRole.assistant && m.hasToolCalls) {
        final content = <Map<String, dynamic>>[];
        if (m.content.trim().isNotEmpty) {
          content.add({'type': 'text', 'text': m.content});
        }
        for (final call in m.toolCalls!) {
          content.add({
            'type': 'tool_use',
            'id': call.id,
            'name': call.name,
            'input': call.arguments,
          });
        }
        out.add({'role': 'assistant', 'content': content});
        continue;
      }

      final imagesBase64 = await _encodeImagesBase64(m);
      if (imagesBase64.isEmpty) {
        out.add({'role': _roleName(m.role), 'content': m.promptContent});
      } else {
        final content = <Map<String, dynamic>>[];
        for (final b64 in imagesBase64) {
          content.add({
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': 'image/jpeg',
              'data': b64,
            },
          });
        }
        if (m.promptContent.isNotEmpty) {
          content.add({'type': 'text', 'text': m.promptContent});
        }
        out.add({'role': _roleName(m.role), 'content': content});
      }
    }
    return out;
  }

  Future<List<String>> _encodeImagesBase64(OllamaMessage m) async {
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

  /// Claude 4.x extended-thinking models (opus-4-*, sonnet-4-6+, haiku-4-5+)
  /// reject `temperature`. Legacy claude-3.x and older 4.x models still take it.
  static bool _acceptsTemperature(String model) {
    final lower = model.toLowerCase();
    if (lower.startsWith('claude-3')) return true;
    return false;
  }

  String _roleName(OllamaMessageRole role) {
    switch (role) {
      case OllamaMessageRole.user:
        return 'user';
      case OllamaMessageRole.assistant:
        return 'assistant';
      case OllamaMessageRole.system:
        return 'user';
      case OllamaMessageRole.tool:
        // Anthropic has no tool role — results are user-turn content blocks,
        // handled ahead of this in _encodeMessages.
        return 'user';
    }
  }
}

class _PartialToolUse {
  final String id;
  final String name;
  final StringBuffer arguments = StringBuffer();

  _PartialToolUse({required this.id, required this.name});
}
