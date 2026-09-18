import 'dart:convert';

/// A tool the model can call, described once in a provider-neutral shape and
/// translated into each provider's dialect by that provider's service.
///
/// [parameters] is a JSON Schema object (`{"type":"object","properties":{...}}`).
/// Both backends accept JSON Schema under `function.parameters`, so one schema
/// covers Ollama and every model OpenRouter serves. The Anthropic
/// (`input_schema`) and Gemini (`functionDeclarations`) dialects went with the
/// direct clients in v4.0.0.
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });

  /// Ollama / OpenAI Chat Completions shape — the only dialect Horizon emits.
  Map<String, dynamic> toOpenAiJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// One model-issued request to run a tool.
///
/// [id] is the provider's correlation handle where there is one (OpenRouter
/// and OpenAI-compatible endpoints send `tool_calls[].id`). Ollama doesn't
/// issue one, so we synthesize it and match results back by name instead —
/// see the per-provider encoders.
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// Tolerant argument decode. Providers stream arguments as a JSON *string*
  /// (OpenAI, Anthropic) or as an already-decoded object (Ollama, Gemini), and
  /// small local models routinely emit a double-encoded string or a bare
  /// value. Never throws: a malformed payload becomes an empty map, and the
  /// tool itself reports the missing argument back to the model, which can
  /// then retry — far better than killing the turn.
  static Map<String, dynamic> parseArguments(dynamic raw) {
    if (raw == null) return const {};
    if (raw is Map) return raw.map((k, v) => MapEntry(k.toString(), v));
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return const {};
      try {
        final decoded = json.decode(trimmed);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v));
        }
        // A bare scalar where an object was expected.
        return {'value': decoded};
      } catch (_) {
        return const {};
      }
    }
    return const {};
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'arguments': arguments,
      };

  factory ToolCall.fromJson(Map<String, dynamic> map) => ToolCall(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        arguments: parseArguments(map['arguments']),
      );

  /// Short human-readable summary for the tool card in the transcript.
  String get summary {
    if (arguments.isEmpty) return name;
    final first = arguments.entries.first;
    final value = first.value.toString();
    final clipped = value.length > 80 ? '${value.substring(0, 80)}…' : value;
    return '$name($clipped)';
  }

  static List<ToolCall> listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => ToolCall.fromJson(m.map((k, v) => MapEntry(k.toString(), v))))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static String? listToJson(List<ToolCall>? calls) {
    if (calls == null || calls.isEmpty) return null;
    return json.encode(calls.map((c) => c.toJson()).toList());
  }
}

/// What a tool produced. [isError] only affects presentation — the text is fed
/// back to the model either way so it can recover or explain the failure.
class ToolResult {
  final String content;
  final bool isError;

  const ToolResult(this.content, {this.isError = false});

  factory ToolResult.error(String message) => ToolResult(message, isError: true);
}
