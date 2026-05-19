import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_model.dart';
import 'package:horizon/Services/chat_service.dart';
import 'package:horizon/Services/claude_service.dart';
import 'package:horizon/Services/gemini_service.dart';
import 'package:horizon/Services/ollama_service.dart';
import 'package:horizon/Services/openai_service.dart';

/// Routes chat operations to the right backend based on `chat.provider`.
class ChatServiceRegistry {
  final OllamaService ollama;
  final ClaudeService claude;
  final OpenAIService openai;
  final GeminiService gemini;

  ChatServiceRegistry({
    required this.ollama,
    required this.claude,
    required this.openai,
    required this.gemini,
  });

  ChatService resolve(String provider) {
    switch (provider) {
      case 'anthropic':
        return claude;
      case 'openai':
        return openai;
      case 'google':
        return gemini;
      case 'ollama':
      default:
        return ollama;
    }
  }

  ChatService forChat(OllamaChat chat) => resolve(chat.provider);

  List<ChatService> get all => [ollama, claude, openai, gemini];

  /// Fetch models from every configured provider. Failures are swallowed
  /// per-provider so one bad key doesn't hide the rest.
  Future<List<OllamaModel>> listAllModels() async {
    final services = all.where((s) => s.isConfigured).toList();
    final results = await Future.wait(services.map((s) async {
      try {
        return await s.listModels();
      } catch (_) {
        return <OllamaModel>[];
      }
    }));
    return results.expand((m) => m).toList();
  }
}
