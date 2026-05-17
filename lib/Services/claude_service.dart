import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_exception.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Models/model_capabilities.dart';
import 'package:horizon/Services/chat_service.dart';
import 'package:horizon/Utils/http_error_formatter.dart';

/// Anthropic Messages API client.
class ClaudeService implements ChatService {
  static const String _baseUrl = 'https://api.anthropic.com';
  static const String _apiVersion = '2023-06-01';

  String _apiKey;
  set apiKey(String? value) => _apiKey = value ?? '';
  String get apiKey => _apiKey;

  ClaudeService({String? apiKey}) : _apiKey = apiKey ?? '';

  @override
  String get providerId => 'anthropic';

  @override
  bool get isConfigured => _apiKey.isNotEmpty;

  Map<String, String> get _headers => {
        'x-api-key': _apiKey,
        'anthropic-version': _apiVersion,
        'content-type': 'application/json',
      };

  @override
  Future<List<OllamaModel>> listModels() async {
    if (!isConfigured) {
      throw OllamaException('Claude API key not set.');
    }

    try {
      final response = await http
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
        HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body),
      );
    } on TimeoutException {
      throw OllamaException('Claude API timed out.');
    } on SocketException {
      throw OllamaException('Network error contacting Claude API.');
    }
  }

  @override
  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
  }) async* {
    if (!isConfigured) {
      throw OllamaException('Claude API key not set.');
    }

    final request = http.Request('POST', Uri.parse('$_baseUrl/v1/messages'));
    request.headers.addAll(_headers);

    final body = <String, dynamic>{
      'model': chat.model,
      'max_tokens': chat.options.maxTokens > 0 ? chat.options.maxTokens : 4096,
      'messages': await _encodeMessages(messages),
      'stream': true,
      'temperature': chat.options.temperature,
    };
    if (chat.systemPrompt != null && chat.systemPrompt!.isNotEmpty) {
      body['system'] = chat.systemPrompt;
    }
    request.body = json.encode(body);

    try {
      final response = await request.send().timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw OllamaException(
          HttpErrorFormatter.formatHttpError(response.statusCode, body: text),
        );
      }

      yield* _parseSse(response.stream, chat.model);
    } on TimeoutException {
      throw OllamaException('Claude API timed out.');
    } on SocketException {
      throw OllamaException('Network error contacting Claude API.');
    }
  }

  Stream<OllamaMessage> _parseSse(Stream<List<int>> stream, String model) async* {
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
          if (type == 'content_block_delta') {
            final delta = event['delta'] as Map<String, dynamic>?;
            final text = delta?['text'] as String?;
            if (text != null && text.isNotEmpty) {
              yield OllamaMessage(
                text,
                role: OllamaMessageRole.assistant,
                model: model,
              );
            }
          } else if (type == 'message_stop') {
            yield OllamaMessage(
              '',
              role: OllamaMessageRole.assistant,
              model: model,
              done: true,
            );
          } else if (type == 'error') {
            final err = event['error'] as Map<String, dynamic>?;
            throw OllamaException(err?['message'] ?? 'Claude stream error');
          }
        } on FormatException {
          continue;
        }
      }
    }
  }

  Future<List<Map<String, dynamic>>> _encodeMessages(List<OllamaMessage> messages) async {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.role == OllamaMessageRole.system) continue;

      final imagesBase64 = await _encodeImagesBase64(m);
      if (imagesBase64.isEmpty) {
        out.add({'role': _roleName(m.role), 'content': m.content});
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
        if (m.content.isNotEmpty) {
          content.add({'type': 'text', 'text': m.content});
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

  String _roleName(OllamaMessageRole role) {
    switch (role) {
      case OllamaMessageRole.user:
        return 'user';
      case OllamaMessageRole.assistant:
        return 'assistant';
      case OllamaMessageRole.system:
        return 'user';
    }
  }
}
