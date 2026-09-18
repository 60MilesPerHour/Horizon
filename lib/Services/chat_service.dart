import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_message.dart';
import 'package:horizon/Models/ollama_model.dart';

/// Unified provider interface. Ollama, OpenRouter, Claude, OpenAI and Gemini
/// all conform.
abstract class ChatService {
  /// Stable identifier for this provider (e.g. 'ollama', 'openrouter').
  String get providerId;

  /// Whether this provider is configured (has key / server address).
  bool get isConfigured;

  /// Whether this provider can carry a tool definition at all. False only for
  /// backends with no function-calling surface; per-*model* support is decided
  /// by the caller from [OllamaModel.capabilities].
  bool get supportsTools => true;

  Future<List<OllamaModel>> listModels();

  /// Streams a response. When [tools] is non-empty the provider must declare
  /// them in its own dialect and surface any tool calls it gets back on the
  /// yielded message's [OllamaMessage.toolCalls]; the caller runs the tools
  /// and sends the results as [OllamaMessageRole.tool] messages.
  Stream<OllamaMessage> chatStream(
    List<OllamaMessage> messages, {
    required OllamaChat chat,
    List<ToolDefinition> tools = const [],
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
