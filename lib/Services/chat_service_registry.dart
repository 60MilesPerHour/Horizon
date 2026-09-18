import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Utils/openrouter_migration.dart';
import 'package:horizon/Services/chat_service.dart';
import 'package:horizon/Services/ollama_service.dart';
import 'package:horizon/Services/openrouter_service.dart';

/// Routes chat operations to the right backend based on `chat.provider`.
///
/// Two backends: Ollama for local models, OpenRouter for everything hosted.
/// Horizon also spoke Anthropic, OpenAI and Google natively until v4.0.0 —
/// three keys, three request dialects, three tool protocols, and capability
/// support that had to be guessed from model names. OpenRouter serves the same
/// models behind one key and reports what each can do, so the direct clients
/// were removed and existing chats migrated onto it; see
/// [OpenRouterMigration].
class ChatServiceRegistry {
  final OllamaService ollama;
  final OpenRouterService openrouter;

  ChatServiceRegistry({
    required this.ollama,
    required this.openrouter,
  });

  ChatService resolve(String provider) {
    switch (provider) {
      case 'openrouter':
        return openrouter;
      case 'ollama':
      default:
        return ollama;
    }
  }

  ChatService forChat(OllamaChat chat) => resolve(chat.provider);

  List<ChatService> get all => [ollama, openrouter];

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
