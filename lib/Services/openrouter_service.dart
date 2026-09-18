import 'package:horizon/Models/model_capabilities.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Services/openai_compatible_service.dart';

/// OpenRouter — one key and one bill for Claude, GPT, Gemini, Llama, Qwen and
/// several hundred others, all behind the OpenAI Chat Completions protocol.
///
/// This is the preferred cloud path in Horizon. Talking to Anthropic, OpenAI
/// and Google directly meant three keys, three request dialects and three tool
/// protocols to keep working; OpenRouter collapses that to one, and unlike
/// those endpoints its model list reports per-model capabilities (tools,
/// image input, reasoning) so the UI can be honest about what a model can do
/// instead of guessing from the model name.
class OpenRouterService extends OpenAiCompatibleService {
  OpenRouterService({super.apiKey, super.baseUrl, super.enabled});

  @override
  String get providerId => 'openrouter';

  @override
  String get logTag => '[OpenRouter]';

  @override
  String get defaultBaseUrl => 'https://openrouter.ai/api';

  /// OpenRouter uses these for request attribution and its public app
  /// rankings. Harmless if absent, so they're sent unconditionally.
  @override
  Map<String, String> get extraHeaders => const {
        'HTTP-Referer': 'https://github.com/60MilesPerHour/Horizon',
        'X-Title': 'Horizon',
      };

  @override
  List<OllamaModel> parseModels(Map<String, dynamic> body) {
    final data = body['data'] as List<dynamic>? ?? const [];
    final out = <OllamaModel>[];

    for (final entry in data) {
      if (entry is! Map) continue;
      final map = entry.map((k, v) => MapEntry(k.toString(), v));

      final id = (map['id'] ?? '').toString();
      if (id.isEmpty) continue;

      final architecture = map['architecture'];
      final inputModalities = architecture is Map
          ? (architecture['input_modalities'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList()
          : const <String>[];
      final outputModalities = architecture is Map
          ? (architecture['output_modalities'] as List<dynamic>? ?? const [])
              .map((e) => e.toString())
              .toList()
          : const <String>[];

      // Image/audio generators and embedding endpoints can't hold a chat.
      if (outputModalities.isNotEmpty && !outputModalities.contains('text')) {
        continue;
      }

      final supported = (map['supported_parameters'] as List<dynamic>? ??
              const [])
          .map((e) => e.toString())
          .toList();

      out.add(OllamaModel.cloud(
        provider: providerId,
        id: id,
        parameterSize: _subtitle(map),
        capabilities: ModelCapabilities(
          completion: true,
          vision: inputModalities.contains('image'),
          tools: supported.contains('tools'),
          thinking: supported.contains('reasoning') ||
              supported.contains('include_reasoning'),
        ),
      ));
    }

    // Vendor-then-model ordering, which is how the ids read and how anyone
    // scanning several hundred entries expects to find one.
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  /// Display line under the model id: its friendly name plus prompt price per
  /// million tokens, or "free" for the `:free` tier. Cost is the thing you
  /// actually want to see when picking from a list this long.
  static String _subtitle(Map<String, dynamic> map) {
    final name = (map['name'] ?? '').toString();
    final pricing = map['pricing'];
    final promptPrice = pricing is Map
        ? double.tryParse((pricing['prompt'] ?? '').toString())
        : null;

    final parts = <String>[];
    if (name.isNotEmpty) parts.add(name);
    if (promptPrice != null) {
      if (promptPrice == 0) {
        parts.add('free');
      } else {
        final perMillion = promptPrice * 1000000;
        parts.add(perMillion >= 1
            ? '\$${perMillion.toStringAsFixed(2)}/M in'
            : '\$${perMillion.toStringAsFixed(3)}/M in');
      }
    }
    return parts.join(' · ');
  }

  /// Reasoning models on OpenRouter take a `reasoning` object rather than a
  /// bare boolean, and only return the reasoning text when asked. Maps
  /// Horizon's tri-state [OllamaChatOptions.think]: null leaves the model's
  /// own default alone.
  @override
  void decorateRequestBody(Map<String, dynamic> body, OllamaChat chat) {
    final think = chat.options.think;
    if (think == null) return;
    if (think) {
      body['reasoning'] = {'effort': 'medium'};
    } else {
      body['reasoning'] = {'exclude': true};
    }
  }

  /// OpenRouter normalises this per upstream model — it strips `temperature`
  /// for models that reject it rather than erroring, so always send it.
  @override
  bool acceptsTemperature(String model) => true;
}
