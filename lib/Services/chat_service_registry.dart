import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Services/chat_service.dart';
import 'package:horizon/Services/claude_service.dart';
import 'package:horizon/Services/gemini_service.dart';
import 'package:horizon/Services/hermes_service.dart';
import 'package:horizon/Services/ollama_service.dart';
import 'package:horizon/Services/openai_service.dart';
import 'package:horizon/Services/openrouter_service.dart';

/// Routes chat operations to the right backend based on `chat.provider`.
///
/// Ollama for local models, OpenRouter as the recommended way to everything
/// hosted. The direct Anthropic, OpenAI and Google clients were removed in
/// v4.0.0 and came back in v4.6.0 for anyone who'd rather use their own key
/// than a middleman; all three ship disabled. Chats migrated off them in
/// v4.0.0 stay on OpenRouter — the migration isn't reversed.
class ChatServiceRegistry {
  final OllamaService ollama;
  final OpenRouterService openrouter;
  final ClaudeService claude;
  final OpenAIService openai;
  final GeminiService gemini;

  /// A Hermes agent on one of your own machines. Optional so call sites that
  /// predate it (tests, mostly) keep compiling; it's simply off there.
  final HermesService hermes;

  ChatServiceRegistry({
    required this.ollama,
    required this.openrouter,
    required this.claude,
    required this.openai,
    required this.gemini,
    HermesService? hermes,
  }) : hermes = hermes ?? HermesService();

  ChatService resolve(String provider) {
    switch (provider) {
      case 'openrouter':
        return openrouter;
      case 'anthropic':
        return claude;
      case 'openai':
        return openai;
      case 'google':
        return gemini;
      case HermesService.id:
        return hermes;
      case 'ollama':
      default:
        return ollama;
    }
  }

  ChatService forChat(OllamaChat chat) => resolve(chat.provider);

  List<ChatService> get all => [ollama, openrouter, claude, openai, gemini, hermes];

  /// Fetch models from every configured provider. Per-provider failures are
  /// tolerated so one bad key doesn't hide the rest — but if EVERY provider
  /// fails, the first real error is rethrown so the UI can say what broke
  /// instead of showing an empty list.
  Future<List<OllamaModel>> listAllModels() async {
    final services = all.where((s) => s.isConfigured).toList();
    final errors = <Object>[];
    final results = await Future.wait(services.map((s) async {
      try {
        return await s.listModels();
      } catch (e) {
        errors.add(e);
        return <OllamaModel>[];
      }
    }));
    final models = results.expand((m) => m).toList();
    if (models.isEmpty && errors.isNotEmpty) {
      throw errors.first;
    }
    return models;
  }
}
