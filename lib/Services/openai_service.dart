import 'package:horizon/Models/model_capabilities.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Services/openai_compatible_service.dart';

/// OpenAI Chat Completions API client.
///
/// Kept for talking to OpenAI (or any OpenAI-compatible endpoint) directly
/// with your own key. For the usual case of "one key, every model", prefer
/// [OpenRouterService] — same protocol, one bill, and per-model capability
/// metadata the OpenAI model list doesn't provide.
class OpenAIService extends OpenAiCompatibleService {
  OpenAIService({super.apiKey, super.baseUrl, super.enabled});

  @override
  String get providerId => 'openai';

  @override
  String get logTag => '[OpenAI]';

  @override
  String get defaultBaseUrl => 'https://api.openai.com';

  @override
  List<OllamaModel> parseModels(Map<String, dynamic> body) {
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
                // Every current chat model on the Completions API takes tools;
                // the list endpoint says nothing about it either way.
                tools: true,
              ),
            ))
        .toList();
  }

  /// o-series reasoning models (o1, o3, o4, etc.) reject `temperature`.
  @override
  bool acceptsTemperature(String model) {
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
