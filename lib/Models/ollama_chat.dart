import 'dart:convert';
import 'package:uuid/uuid.dart';

class OllamaChat {
  final String id;
  final String model;
  final String title;
  final String? systemPrompt;
  final OllamaChatOptions options;

  /// Backing provider for this chat: 'ollama' (default), 'anthropic', 'openai'.
  final String provider;

  /// Chat this one was branched from, or null if it wasn't. Kept so the UI can
  /// offer a way back to the original — a branch with no visible lineage is
  /// just a mystery duplicate in the sidebar.
  final String? parentChatId;

  /// Message in the parent that this branch was taken after.
  final String? branchPointMessageId;

  bool get isBranch => parentChatId != null;

  OllamaChat({
    String? id,
    required this.model,
    String? title,
    this.systemPrompt,
    OllamaChatOptions? options,
    String? provider,
    this.parentChatId,
    this.branchPointMessageId,
  })  : id = id ?? Uuid().v4(),
        title = title ?? 'New Chat',
        options = options ?? OllamaChatOptions(),
        provider = provider ?? 'ollama';

  factory OllamaChat.fromMap(Map<String, dynamic> map) {
    final model = map['model'] as String? ?? '';
    final storedProvider = map['provider'] as String?;
    return OllamaChat(
      id: map['chat_id'],
      model: model,
      title: map['chat_title'],
      systemPrompt: map['system_prompt'],
      options: map['options'] != null ? OllamaChatOptions.fromJson(map['options']) : null,
      provider: inferProvider(model, storedProvider),
      parentChatId: map['parent_chat_id'] as String?,
      branchPointMessageId: map['branch_point_message_id'] as String?,
    );
  }

  /// Self-healing: if the stored provider doesn't match the model name shape,
  /// pick the obvious one. Protects against rows written before per-chat
  /// routing was wired correctly, or with a stale schema.
  static String inferProvider(String model, String? storedProvider) {
    // OpenRouter ids are `vendor/model`, so none of the bare-prefix rules
    // below can match one — but trust the stored value outright rather than
    // relying on that, since the vendor list grows on OpenRouter's schedule.
    if (storedProvider == 'openrouter') return 'openrouter';

    final lower = model.toLowerCase();
    if (lower.startsWith('claude-')) return 'anthropic';
    if (lower.startsWith('gpt-') || lower.startsWith('o1') ||
        lower.startsWith('o3') || lower.startsWith('o4') ||
        lower.startsWith('chatgpt-')) {
      return 'openai';
    }
    if (lower.startsWith('gemini-') ||
        lower.startsWith('models/gemini-') ||
        lower.startsWith('gemma-')) {
      return 'google';
    }
    return storedProvider ?? 'ollama';
  }
}

/// Represents configuration options for controlling the behavior of the Ollama chat model.
class OllamaChatOptions {
  /// Enables Mirostat sampling for controlling perplexity.
  /// 0 = disabled, 1 = Mirostat, 2 = Mirostat 2.0.
  int mirostat;

  /// Influences how quickly the algorithm responds to feedback from the generated text.
  /// A lower value results in slower adjustments; a higher value makes the algorithm more responsive.
  double mirostatEta;

  /// Controls the balance between coherence and diversity of the output.
  /// A lower value results in more focused and coherent text.
  double mirostatTau;

  /// Sets the size of the context window used to generate the next token.
  int contextSize;

  /// Sets how far back the model looks to prevent repetition.
  /// 0 = disabled, -1 = full context size.
  int repeatLastN;

  /// Sets the strength of penalizing repetitions.
  /// A higher value (e.g., 1.5) penalizes repetitions more strongly.
  double repeatPenalty;

  /// Controls the temperature of the model.
  /// Higher values result in more creative outputs, lower values in more deterministic outputs.
  double temperature;

  /// Sets the random seed for text generation.
  /// A specific value ensures the same text is generated for the same input.
  int seed;

  /// Controls tail-free sampling to reduce the impact of less probable tokens.
  /// 1.0 disables this setting; higher values reduce the impact more.
  double tailFreeSampling;

  /// Sets the maximum number of tokens to predict during text generation.
  /// -1 = infinite generation.
  int maxTokens;

  /// Limits the probability of generating nonsense.
  /// A higher value (e.g., 100) allows more diverse answers, while a lower value (e.g., 10) is more conservative.
  int topK;

  /// Works with topK to control text diversity.
  /// Higher values lead to more diverse text, lower values to more focused text.
  double topP;

  /// Ensures a balance of quality and variety by setting a minimum token probability relative to the most likely token.
  /// Tokens with lower probability are filtered out.
  double minP;

  /// Whether to enable the model's "thinking" phase, for Ollama models that
  /// support it (Qwen 3, gpt-oss, etc.). Tri-state:
  ///   null  → don't send the field; let the model use its default
  ///   true  → force thinking on
  ///   false → force thinking off (no_think)
  /// Models without a thinking phase ignore this flag.
  bool? think;

  /// Whether the model may use tools — web search, page fetching, and the
  /// clock. On by default, because a tool is only ever invoked when the model
  /// decides it needs one.
  ///
  /// Models that advertise tool support get the tools declared natively in
  /// their provider's protocol. Models that don't fall back to the older
  /// prompt-convention search pass, and only when a search backend is
  /// configured. Persisted per-chat; like [think], NOT part of the Ollama
  /// `options` payload — see [toMap].
  bool tools;

  /// Whether to ask the model to emit substantial standalone deliverables
  /// (full documents, complete files) wrapped in `<artifact>` tags, which the
  /// client renders as a collapsed card + a dedicated viewer instead of inline
  /// text. Short snippets stay as normal code blocks. Persisted per-chat;
  /// NOT part of the Ollama `options` payload — see [toMap].
  bool artifacts;

  /// Creates an instance of [OllamaChatOptions] with default values.
  OllamaChatOptions({
    int? mirostat,
    double? mirostatEta,
    double? mirostatTau,
    int? contextSize,
    int? repeatLastN,
    double? repeatPenalty,
    double? temperature,
    int? seed,
    double? tailFreeSampling,
    int? maxTokens,
    int? topK,
    double? topP,
    double? minP,
    this.think,
    bool? tools,
    bool? artifacts,
  })  : tools = tools ?? true,
        artifacts = artifacts ?? false,
        mirostat = mirostat ?? 0,
        mirostatEta = mirostatEta ?? 0.1,
        mirostatTau = mirostatTau ?? 5.0,
        contextSize = contextSize ?? 0,
        repeatLastN = repeatLastN ?? 64,
        repeatPenalty = repeatPenalty ?? 1.1,
        temperature = temperature ?? 0.8,
        seed = seed ?? 0,
        tailFreeSampling = tailFreeSampling ?? 1.0,
        maxTokens = maxTokens ?? -1,
        topK = topK ?? 40,
        topP = topP ?? 0.9,
        minP = minP ?? 0.0;

  /// Factory method for creating an instance of [OllamaChatOptions] from a map.
  factory OllamaChatOptions.fromMap(Map<String, dynamic> map) {
    return OllamaChatOptions(
      mirostat: map['mirostat'],
      mirostatEta: map['mirostat_eta']?.toDouble(),
      mirostatTau: map['mirostat_tau']?.toDouble(),
      // Pre-v3.2.1 chats baked in the old default of 2048, which forced Ollama
      // to unload/reload models that were running at a different context size.
      // Treat 2048 from disk as "use server default" so the override doesn't
      // silently override.
      contextSize: map['num_ctx'] == 2048 ? 0 : map['num_ctx'],
      repeatLastN: map['repeat_last_n'],
      repeatPenalty: map['repeat_penalty']?.toDouble(),
      temperature: map['temperature']?.toDouble(),
      seed: map['seed'],
      tailFreeSampling: map['tfs_z']?.toDouble(),
      maxTokens: map['num_predict'],
      topK: map['top_k'],
      topP: map['top_p']?.toDouble(),
      minP: map['min_p']?.toDouble(),
      think: map['think'] is bool ? map['think'] as bool : null,
      // `web_search` is the pre-v3.8 key for the same switch: a chat that had
      // search on keeps tools on, and one that predates either key gets the
      // new default rather than being silently opted out.
      tools: map['tools'] is bool
          ? map['tools'] as bool
          : (map['web_search'] is bool ? map['web_search'] as bool : null),
      artifacts: map['artifacts'] is bool ? map['artifacts'] as bool : null,
    );
  }

  /// Factory method for creating an instance of [OllamaChatOptions] from a JSON string.
  factory OllamaChatOptions.fromJson(String json) {
    return OllamaChatOptions.fromMap(jsonDecode(json));
  }

  /// Converts the instance of [OllamaChatOptions] to a map suitable for the
  /// Ollama API's `options` field. `think` is intentionally omitted — it's a
  /// top-level request field, not part of `options`.
  Map<String, dynamic> toMap() {
    return {
      'mirostat': mirostat,
      'mirostat_eta': mirostatEta,
      'mirostat_tau': mirostatTau,
      if (contextSize > 0) 'num_ctx': contextSize,
      'repeat_last_n': repeatLastN,
      'repeat_penalty': repeatPenalty,
      'temperature': temperature,
      'seed': seed,
      'tfs_z': tailFreeSampling,
      if (maxTokens > 0) 'num_predict': maxTokens,
      'top_k': topK,
      'top_p': topP,
      'min_p': minP,
    };
  }

  /// Converts the instance of [OllamaChatOptions] to a JSON string suitable
  /// for DB storage. Includes `think` (which `toMap` excludes) so per-chat
  /// thinking preference survives across app restarts.
  String toJson() {
    final m = toMap();
    if (think != null) m['think'] = think;
    // Always written, unlike the flags below: `tools` defaults to true, so
    // omitting it when false would silently re-enable it on the next load.
    m['tools'] = tools;
    if (artifacts) m['artifacts'] = true;
    return jsonEncode(m);
  }
}
