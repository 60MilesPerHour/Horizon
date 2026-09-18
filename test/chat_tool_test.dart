import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Services/openrouter_service.dart';
import 'package:horizon/Services/tool_service.dart';
import 'package:horizon/Services/web_search_service.dart';

/// Wraps SSE event bodies into the chunked byte stream a real response looks
/// like, splitting mid-payload so the parser's buffering is actually exercised.
Stream<List<int>> sse(List<String> lines, {int chunkSize = 7}) async* {
  final payload = lines.map((l) => '$l\n').join();
  final bytes = utf8.encode(payload);
  for (var i = 0; i < bytes.length; i += chunkSize) {
    yield bytes.sublist(i, (i + chunkSize).clamp(0, bytes.length));
  }
}

String dataLine(Map<String, dynamic> event) => 'data: ${json.encode(event)}';

void main() {
  group('ToolCall.parseArguments', () {
    test('decodes a JSON string', () {
      expect(
        ToolCall.parseArguments('{"query":"ollama release notes"}'),
        {'query': 'ollama release notes'},
      );
    });

    test('passes through an already-decoded map', () {
      expect(ToolCall.parseArguments({'url': 'https://example.com'}),
          {'url': 'https://example.com'});
    });

    test('wraps a bare scalar rather than losing it', () {
      expect(ToolCall.parseArguments('"just a string"'), {'value': 'just a string'});
    });

    test('returns empty for malformed JSON instead of throwing', () {
      // Small local models truncate arguments; the tool then reports the
      // missing argument back to the model, which can retry.
      expect(ToolCall.parseArguments('{"query":"unclos'), isEmpty);
      expect(ToolCall.parseArguments(null), isEmpty);
      expect(ToolCall.parseArguments(''), isEmpty);
    });
  });

  group('ToolDefinition dialects', () {
    const tool = ToolDefinition(
      name: 'web_search',
      description: 'Search the web',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'default': 'x'},
        },
        'required': ['query'],
        'additionalProperties': false,
      },
    );

    test('OpenAI/Ollama shape nests under function', () {
      final json = tool.toOpenAiJson();
      expect(json['type'], 'function');
      expect(json['function']['name'], 'web_search');
      expect(json['function']['parameters']['type'], 'object');
    });

    test('the schema is passed through verbatim', () {
      // No dialect filtering any more: the Gemini sanitiser went with the
      // direct clients in v4.0.0, and OpenRouter takes JSON Schema as-is.
      final params =
          tool.toOpenAiJson()['function']['parameters'] as Map<String, dynamic>;
      expect(params['additionalProperties'], isFalse);
      expect(params['required'], ['query']);
    });
  });

  group('OpenAI-compatible SSE tool-call reassembly', () {
    final service = OpenRouterService(apiKey: 'test', enabled: true);

    test('stitches arguments split across many deltas', () async {
      final messages = await service
          .parseSse(
            sse([
              dataLine({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'call_abc',
                          'function': {'name': 'web_search', 'arguments': ''},
                        }
                      ]
                    }
                  }
                ]
              }),
              dataLine({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'function': {'arguments': '{"qu'},
                        }
                      ]
                    }
                  }
                ]
              }),
              dataLine({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'function': {'arguments': 'ery":"reins 2.3"}'},
                        }
                      ]
                    }
                  }
                ]
              }),
              'data: [DONE]',
            ]),
            'gpt-test',
          )
          .toList();

      final calls = messages.last.toolCalls;
      expect(calls, isNotNull);
      expect(calls!.length, 1);
      expect(calls.first.id, 'call_abc');
      expect(calls.first.name, 'web_search');
      expect(calls.first.arguments, {'query': 'reins 2.3'});
    });

    test('keeps parallel calls separate and ordered by index', () async {
      final messages = await service
          .parseSse(
            sse([
              dataLine({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 1,
                          'id': 'b',
                          'function': {
                            'name': 'current_time',
                            'arguments': '{}',
                          },
                        },
                        {
                          'index': 0,
                          'id': 'a',
                          'function': {
                            'name': 'web_fetch',
                            'arguments': '{"url":"https://a.test"}',
                          },
                        },
                      ]
                    }
                  }
                ]
              }),
              dataLine({
                'choices': [
                  {'delta': {}, 'finish_reason': 'tool_calls'}
                ]
              }),
            ]),
            'gpt-test',
          )
          .toList();

      final calls = messages.last.toolCalls!;
      expect(calls.map((c) => c.name), ['web_fetch', 'current_time']);
      expect(calls.first.arguments, {'url': 'https://a.test'});
    });

    test('emits text deltas as they arrive and finishes on finish_reason',
        () async {
      final messages = await service
          .parseSse(
            sse([
              dataLine({
                'choices': [
                  {
                    'delta': {'content': 'Hello '}
                  }
                ]
              }),
              dataLine({
                'choices': [
                  {
                    'delta': {'content': 'world'}
                  }
                ]
              }),
              dataLine({
                'choices': [
                  {'delta': {}, 'finish_reason': 'stop'}
                ]
              }),
            ]),
            'gpt-test',
          )
          .toList();

      expect(messages.map((m) => m.content).join(), 'Hello world');
      expect(messages.last.done, isTrue);
      expect(messages.last.toolCalls, isNull);
    });

    test('still delivers tool calls when the stream ends with no sentinel',
        () async {
      // Some gateways just close the connection.
      final messages = await service
          .parseSse(
            sse([
              dataLine({
                'choices': [
                  {
                    'delta': {
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'x',
                          'function': {
                            'name': 'current_time',
                            'arguments': '{}',
                          },
                        }
                      ]
                    }
                  }
                ]
              }),
            ]),
            'gpt-test',
          )
          .toList();

      expect(messages.last.toolCalls?.single.name, 'current_time');
    });
  });

  group('OpenAI-compatible transcript encoding', () {
    final service = OpenRouterService(apiKey: 'test', enabled: true);

    test('replays tool calls and results in the protocol shape', () async {
      final call = ToolCall(
        id: 'call_1',
        name: 'current_time',
        arguments: const {},
      );
      final encoded = await service.encodeMessages([
        OllamaMessage('what time is it', role: OllamaMessageRole.user),
        OllamaMessage('', role: OllamaMessageRole.assistant, toolCalls: [call]),
        OllamaMessage.toolResult(
          call: call,
          result: const ToolResult('Tuesday'),
        ),
      ], 'be brief');

      expect(encoded[0], {'role': 'system', 'content': 'be brief'});
      expect(encoded[1]['role'], 'user');
      // A tool-calls-only turn sends content: null, not an empty string.
      expect(encoded[2]['content'], isNull);
      expect(encoded[2]['tool_calls'][0]['function']['name'], 'current_time');
      expect(encoded[3], {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': 'Tuesday',
      });
    });
  });

  group('ToolService', () {
    final service = ToolService(webSearch: WebSearchService());

    test('offers web_fetch and the clock with no search backend', () {
      final names = service.availableTools().map((t) => t.name).toList();
      expect(names, contains('web_fetch'));
      expect(names, contains('current_time'));
      // Declaring a search tool with no backend invites the model to call it
      // and then apologise.
      expect(names, isNot(contains('web_search')));
    });

    test('offers web_search once a backend is configured', () {
      final configured = ToolService(
        webSearch: WebSearchService(
          backend: WebSearchBackend.serpapi,
          serpApiKey: 'key',
        ),
      );
      expect(
        configured.availableTools().map((t) => t.name),
        containsAll(['web_search', 'web_fetch', 'current_time']),
      );
    });

    test('current_time returns a parseable ISO timestamp', () async {
      final result = await service.execute(
        const ToolCall(id: '1', name: 'current_time', arguments: {}),
      );
      expect(result.isError, isFalse);
      final iso = RegExp(r'ISO 8601: (\S+)').firstMatch(result.content);
      expect(iso, isNotNull);
      expect(DateTime.parse(iso!.group(1)!), isA<DateTime>());
    });

    test('an unknown tool reports the real tool names back to the model',
        () async {
      final result = await service.execute(
        const ToolCall(id: '1', name: 'make_coffee', arguments: {}),
      );
      expect(result.isError, isTrue);
      expect(result.content, contains('current_time'));
    });

    test('a missing argument is reported, not thrown', () async {
      final result = await service.execute(
        const ToolCall(id: '1', name: 'web_fetch', arguments: {}),
      );
      expect(result.isError, isTrue);
      expect(result.content, contains('url'));
    });

    test('accepts a renamed argument rather than wasting a round trip',
        () async {
      // Small models routinely send "link" for "url".
      final result = await service.execute(
        const ToolCall(
          id: '1',
          name: 'web_fetch',
          arguments: {'link': 'not a url at all'},
        ),
      );
      // It got as far as URL validation, which means the argument was found
      // under its renamed key — and the rejection says what a URL looks like
      // rather than leaking a FormatException about link-local addresses.
      expect(result.isError, isTrue);
      expect(result.content, contains('not a URL that can be fetched'));
      expect(result.content, contains('https://example.com'));
    });
  });

  group('OllamaMessage prompt composition', () {
    test('tool results round-trip through the database map', () {
      final call = ToolCall(
        id: 'call_9',
        name: 'web_search',
        arguments: const {'query': 'horizon'},
      );
      final assistant = OllamaMessage(
        '',
        role: OllamaMessageRole.assistant,
        toolCalls: [call],
      );

      final map = assistant.toDatabaseMap();
      expect(map['role'], 'assistant');

      final restored = OllamaMessage.fromDatabase({
        ...map,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'model': null,
      });
      expect(restored.hasToolCalls, isTrue);
      expect(restored.toolCalls!.single.arguments, {'query': 'horizon'});
    });

    test('a tool message keeps its correlation keys', () {
      final call = ToolCall(id: 'c1', name: 'current_time', arguments: const {});
      final message = OllamaMessage.toolResult(
        call: call,
        result: ToolResult.error('boom'),
      );
      expect(message.role, OllamaMessageRole.tool);
      expect(message.toolCallId, 'c1');
      expect(message.toolName, 'current_time');
      expect(message.toolFailed, isTrue);
    });
  });
}
