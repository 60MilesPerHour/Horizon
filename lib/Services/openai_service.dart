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

/// OpenAI Chat Completions API client (also works with OpenAI-compatible endpoints).
class OpenAIService extends ChatService {
  String _apiKey;
  String _baseUrl;

  OpenAIService({String? apiKey, String? baseUrl})
      : _apiKey = apiKey ?? '',
        _baseUrl = baseUrl ?? 'https://api.openai.com';

  set apiKey(String? value) => _apiKey = value ?? '';
  String get apiKey => _apiKey;

  set baseUrl(String? value) => _baseUrl = (value == null || value.isEmpty) ? 'https://api.openai.com' : value;
  String get baseUrl => _baseUrl;

  @override
  String get providerId => 'openai';

  @override
  bool get isConfigured => _apiKey.isNotEmpty;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_apiKey',
        'content-type': 'application/json',
      };

  @override
  Future<List<OllamaModel>> listModels() async {
    if (!isConfigured) {
      throw OllamaException('[OpenAI] API key not set.');
    }

    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/v1/models'), headers: _headers)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final body = json.decode(response.body);
        final data = body['data'] as List<dynamic>? ?? [];
        final ids = data.map((m) => m['id'] as String).toList();
        final chatIds = ids.where(_isChatModel).toList()..sort();
        return chatIds
            .map((id) => OllamaModel.cloud(
                  provider: providerId,
                  id: id,
                  capabilities: ModelCapabilities(
                    completion: true,
                    vision: _isVisionModel(id),
                    thinking: _isThinkingModel(id),
                  ),
                ))
            .toList();
      }

      throw OllamaException(
        '[OpenAI] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}',
      );
    } on TimeoutException {
      throw OllamaException('[OpenAI] API timed out.');
    } on SocketException {
      throw OllamaException('[OpenAI] Network error contacting API.');
    }
  }

  @override
  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
  }) async* {
    if (!isConfigured) {
      throw OllamaException('[OpenAI] API key not set.');
    }

    final request = http.Request('POST', Uri.parse('$_baseUrl/v1/chat/completions'));
    request.headers.addAll(_headers);

    final body = <String, dynamic>{
      'model': chat.model,
      'messages': await _encodeMessages(messages, chat.systemPrompt),
      'stream': true,
    };
    // o-series reasoning models (o1, o3, o4, etc.) reject `temperature`.
    if (_acceptsTemperature(chat.model)) {
      body['temperature'] = chat.options.temperature;
    }
    if (chat.options.maxTokens > 0) {
      body['max_completion_tokens'] = chat.options.maxTokens;
    }
    request.body = json.encode(body);

    try {
      final response = await request.send().timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw OllamaException(
          '[OpenAI] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: text)}',
        );
      }

      yield* _parseSse(response.stream, chat.model);
    } on TimeoutException {
      throw OllamaException('[OpenAI] API timed out.');
    } on SocketException {
      throw OllamaException('[OpenAI] Network error contacting API.');
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
        if (payload == '[DONE]') {
          yield OllamaMessage('', role: OllamaMessageRole.assistant, model: model, done: true);
          return;
        }

        try {
          final event = json.decode(payload) as Map<String, dynamic>;
          final choices = event['choices'] as List<dynamic>?;
          if (choices == null || choices.isEmpty) continue;
          final delta = choices.first['delta'] as Map<String, dynamic>?;
          final text = delta?['content'] as String?;
          if (text != null && text.isNotEmpty) {
            yield OllamaMessage(
              text,
              role: OllamaMessageRole.assistant,
              model: model,
            );
          }
        } on FormatException {
          continue;
        }
      }
    }
  }

  Future<List<Map<String, dynamic>>> _encodeMessages(
    List<OllamaMessage> messages,
    String? systemPrompt,
  ) async {
    final out = <Map<String, dynamic>>[];
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      out.add({'role': 'system', 'content': systemPrompt});
    }

    for (final m in messages) {
      if (m.role == OllamaMessageRole.system) continue;
      final images = await _encodeImagesBase64(m);
      if (images.isEmpty) {
        out.add({'role': _roleName(m.role), 'content': m.content});
      } else {
        final content = <Map<String, dynamic>>[];
        if (m.content.isNotEmpty) {
          content.add({'type': 'text', 'text': m.content});
        }
        for (final b64 in images) {
          content.add({
            'type': 'image_url',
            'image_url': {'url': 'data:image/jpeg;base64,$b64'},
          });
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
        return 'system';
    }
  }

  static bool _acceptsTemperature(String model) {
    final lower = model.toLowerCase();
    if (lower.startsWith('o1') || lower.startsWith('o3') || lower.startsWith('o4')) {
      return false;
    }
    return true;
  }

  static bool _isChatModel(String id) {
    final lower = id.toLowerCase();
    if (lower.contains('embed') || lower.contains('whisper') ||
        lower.contains('tts') || lower.contains('dall-e') ||
        lower.contains('moderation') || lower.contains('audio') ||
        lower.contains('image') || lower.contains('davinci') ||
        lower.contains('babbage')) {
      return false;
    }
    return lower.startsWith('gpt-') || lower.startsWith('o1') ||
           lower.startsWith('o3') || lower.startsWith('o4') ||
           lower.startsWith('chatgpt-');
  }

  static bool _isVisionModel(String id) {
    final lower = id.toLowerCase();
    return lower.contains('4o') || lower.contains('4.1') ||
           lower.contains('vision') || lower.startsWith('o1') ||
           lower.startsWith('o3') || lower.startsWith('o4');
  }

  static bool _isThinkingModel(String id) {
    final lower = id.toLowerCase();
    return lower.startsWith('o1') || lower.startsWith('o3') || lower.startsWith('o4');
  }
}
