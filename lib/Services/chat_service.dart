import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';

/// Unified provider interface. Ollama, Claude, and OpenAI all conform.
abstract class ChatService {
  /// Stable identifier for this provider (e.g. 'ollama', 'anthropic', 'openai').
  String get providerId;

  /// Whether this provider is configured (has key / server address).
  bool get isConfigured;

  Future<List<OllamaModel>> listModels();

  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
  });

  /// One-shot single-prompt generation used for chat title generation.
  /// Default impl wraps chatStream with a single user message.
  Stream<OllamaMessage> generateStream(
    String prompt, {
    required OllamaChat chat,
  }) async* {
    final synthetic = [OllamaMessage(prompt, role: OllamaMessageRole.user)];
    yield* chatStream(synthetic, chat: chat);
  }

  /// Optional: clone a chat into a new local model. Not supported by cloud providers.
  Future<void> createModel(
    String model, {
    required OllamaChat chat,
    List<OllamaMessage>? messages,
  }) async {
    throw UnsupportedError('$providerId does not support saving models.');
  }
}
