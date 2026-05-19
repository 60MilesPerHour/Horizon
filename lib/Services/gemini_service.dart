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

/// Google Gemini (Generative Language API) client.
class GeminiService extends ChatService {
  static const String _baseUrl = 'https://generativelanguage.googleapis.com';
  static const String _apiVersion = 'v1beta';

  String _apiKey;
  set apiKey(String? value) => _apiKey = value ?? '';
  String get apiKey => _apiKey;

  GeminiService({String? apiKey}) : _apiKey = apiKey ?? '';

  @override
  String get providerId => 'google';

  @override
  bool get isConfigured => _apiKey.isNotEmpty;

  Map<String, String> get _jsonHeaders => {
        'content-type': 'application/json',
      };

  @override
  Future<List<OllamaModel>> listModels() async {
    if (!isConfigured) {
      throw OllamaException('[Gemini] API key not set.');
    }

    try {
      final url = Uri.parse('$_baseUrl/$_apiVersion/models?key=$_apiKey');
      final response = await http.get(url).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final body = json.decode(response.body) as Map<String, dynamic>;
        final list = (body['models'] as List<dynamic>? ?? []);
        final out = <OllamaModel>[];
        for (final entry in list) {
          final m = entry as Map<String, dynamic>;
          final methods = (m['supportedGenerationMethods'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList();
          if (!methods.contains('generateContent') &&
              !methods.contains('streamGenerateContent')) {
            continue;
          }
          // Names come as "models/gemini-1.5-pro" — strip the prefix.
          final fullName = (m['name'] as String?) ?? '';
          final id = fullName.startsWith('models/') ? fullName.substring(7) : fullName;
          if (id.isEmpty) continue;
          // Skip embedding / image / non-text variants.
          final lower = id.toLowerCase();
          if (lower.contains('embedding') ||
              lower.contains('aqa') ||
              lower.contains('image') ||
              lower.contains('imagen')) continue;
          final displayName = (m['displayName'] as String?) ?? id;
          out.add(OllamaModel.cloud(
            provider: providerId,
            id: id,
            parameterSize: displayName,
            capabilities: ModelCapabilities(
              completion: true,
              vision: _isVisionModel(id),
              thinking: _isThinkingModel(id),
            ),
          ));
        }
        out.sort((a, b) => a.name.compareTo(b.name));
        return out;
      }

      throw OllamaException(
        '[Gemini] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: response.body)}',
      );
    } on TimeoutException {
      throw OllamaException('[Gemini] API timed out.');
    } on SocketException {
      throw OllamaException('[Gemini] Network error contacting API.');
    }
  }

  @override
  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
  }) async* {
    if (!isConfigured) {
      throw OllamaException('[Gemini] API key not set.');
    }

    final url = Uri.parse(
      '$_baseUrl/$_apiVersion/models/${chat.model}:streamGenerateContent?alt=sse&key=$_apiKey',
    );
    final request = http.Request('POST', url);
    request.headers.addAll(_jsonHeaders);

    final body = <String, dynamic>{
      'contents': await _encodeContents(messages),
      'generationConfig': {
        'temperature': chat.options.temperature,
        if (chat.options.maxTokens > 0) 'maxOutputTokens': chat.options.maxTokens,
        if (chat.options.topP != 0.9) 'topP': chat.options.topP,
        if (chat.options.topK != 40) 'topK': chat.options.topK,
      },
    };
    if (chat.systemPrompt != null && chat.systemPrompt!.isNotEmpty) {
      body['systemInstruction'] = {
        'parts': [
          {'text': chat.systemPrompt}
        ],
      };
    }
    request.body = json.encode(body);

    try {
      final response = await request.send().timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw OllamaException(
          '[Gemini] ${HttpErrorFormatter.formatHttpError(response.statusCode, body: text)}',
        );
      }

      yield* _parseSse(response.stream, chat.model);
    } on TimeoutException {
      throw OllamaException('[Gemini] API timed out.');
    } on SocketException {
      throw OllamaException('[Gemini] Network error contacting API.');
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
          final candidates = event['candidates'] as List<dynamic>?;
          if (candidates == null || candidates.isEmpty) continue;
          final c = candidates.first as Map<String, dynamic>;

          final content = c['content'] as Map<String, dynamic>?;
          final parts = content?['parts'] as List<dynamic>? ?? const [];
          for (final p in parts) {
            final text = (p as Map<String, dynamic>)['text'] as String?;
            if (text != null && text.isNotEmpty) {
              yield OllamaMessage(
                text,
                role: OllamaMessageRole.assistant,
                model: model,
              );
            }
          }

          final finishReason = c['finishReason'] as String?;
          if (finishReason != null && finishReason != 'FINISH_REASON_UNSPECIFIED') {
            yield OllamaMessage(
              '',
              role: OllamaMessageRole.assistant,
              model: model,
              done: true,
            );
            return;
          }
        } on FormatException {
          continue;
        }
      }
    }
  }

  Future<List<Map<String, dynamic>>> _encodeContents(List<OllamaMessage> messages) async {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.role == OllamaMessageRole.system) continue;

      final parts = <Map<String, dynamic>>[];

      final imagesBase64 = await _encodeImagesBase64(m);
      for (final b64 in imagesBase64) {
        parts.add({
          'inline_data': {
            'mime_type': 'image/jpeg',
            'data': b64,
          },
        });
      }
      if (m.content.isNotEmpty) {
        parts.add({'text': m.content});
      }

      if (parts.isEmpty) continue;
      out.add({
        'role': _roleName(m.role),
        'parts': parts,
      });
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
        return 'model';
      case OllamaMessageRole.system:
        return 'user';
    }
  }

  static bool _isVisionModel(String id) {
    final lower = id.toLowerCase();
    // 1.5+ and 2.x families are all multimodal.
    return lower.contains('1.5') ||
        lower.contains('2.0') ||
        lower.contains('2.5') ||
        lower.contains('pro') ||
        lower.contains('flash');
  }

  static bool _isThinkingModel(String id) {
    final lower = id.toLowerCase();
    return lower.contains('thinking') || lower.contains('2.5') || lower.contains('2.0-flash-thinking');
  }
}
