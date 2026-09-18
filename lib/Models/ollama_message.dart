import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/attachment.dart';
import 'package:horizon/Models/chat_tool.dart';
import 'package:uuid/uuid.dart';

class OllamaMessage {
  /// The unique identifier of the message.
  String id;

  /// The text content of the message.
  String content;

  /// The image content of the message.
  List<File>? images;

  /// Documents (PDF / CSV / text / code) attached to the message. Their
  /// extracted text is folded into [promptContent] on the way to the model;
  /// the bubble shows them as chips.
  List<Attachment>? attachments;

  /// Tools this assistant message asked to run. Non-null only on assistant
  /// messages, and only when the provider returned tool calls. Each one is
  /// answered by a following [OllamaMessageRole.tool] message.
  List<ToolCall>? toolCalls;

  /// For [OllamaMessageRole.tool] messages: which call this is the result of.
  /// [toolCallId] correlates with the provider's own id where it issues one
  /// (OpenAI, Anthropic); [toolName] is the fallback correlation key for
  /// Ollama and Gemini, which don't.
  String? toolCallId;
  String? toolName;

  /// For tool messages: whether the tool reported a failure. Presentation
  /// only — the text goes back to the model either way.
  bool toolFailed;

  /// The date and time the message was created.
  DateTime createdAt;

  /// The role of the message.
  OllamaMessageRole role;

  /// The model used to generate the message.
  String? model;

  // Metadata fields
  bool? done;
  String? doneReason;
  List<int>? context;
  int? totalDuration;
  int? loadDuration;
  int? promptEvalCount;
  int? promptEvalDuration;
  int? evalCount;
  int? evalDuration;

  OllamaMessage(
    this.content, {
    String? id,
    required this.role,
    this.images,
    this.attachments,
    this.toolCalls,
    this.toolCallId,
    this.toolName,
    bool? toolFailed,
    DateTime? createdAt,
    this.model,
    this.done,
    this.doneReason,
    this.context,
    this.totalDuration,
    this.loadDuration,
    this.promptEvalCount,
    this.promptEvalDuration,
    this.evalCount,
    this.evalDuration,
  })  : id = id ?? Uuid().v4(),
        toolFailed = toolFailed ?? false,
        createdAt = createdAt ?? DateTime.now();

  /// A tool-result message, ready to be appended to the transcript and sent
  /// back to the model.
  factory OllamaMessage.toolResult({
    required ToolCall call,
    required ToolResult result,
  }) =>
      OllamaMessage(
        result.content,
        role: OllamaMessageRole.tool,
        toolCallId: call.id,
        toolName: call.name,
        toolFailed: result.isError,
      );

  /// Whether this assistant message asked for at least one tool to run.
  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;

  bool get hasAttachments => attachments != null && attachments!.isNotEmpty;

  /// What the model should actually see: the user's text with every
  /// attachment's extracted text appended in a labelled block. The stored
  /// [content] stays clean so the bubble, export, and edit flows show what
  /// the user typed rather than a wall of document text.
  String get promptContent {
    if (!hasAttachments) return content;
    final buffer = StringBuffer();
    for (final attachment in attachments!) {
      buffer.writeln(attachment.toPromptBlock());
      buffer.writeln();
    }
    if (content.trim().isEmpty) {
      // An attachment with no prompt still needs an instruction, or small
      // models just describe the delimiter format back at the user.
      buffer.write('Read the attached file(s) above and summarise them.');
    } else {
      buffer.write(content);
    }
    return buffer.toString();
  }

  factory OllamaMessage.fromJson(Map<String, dynamic> json) {
    final message = json["message"] as Map<String, dynamic>?;
    return OllamaMessage(
      message != null
          ? (message["content"] as String? ?? '') // For chat messages
          : (json["response"] as String? ?? ''), // For generated messages
      role: message != null
          ? OllamaMessageRole.fromString(message["role"])
          : OllamaMessageRole.assistant, // For generated messages (default)
      images: null, // Sent, never received.
      toolCalls: _toolCallsFromOllama(message?["tool_calls"]),
      createdAt: json["created_at"] != null
          ? DateTime.parse(json["created_at"])
          : DateTime.now(),
      model: json["model"],
      // Metadata fields
      done: json["done"],
      doneReason: json["done_reason"],
      context: json["context"] != null
          ? List<int>.from(json["context"].map((x) => x))
          : null,
      totalDuration: json["total_duration"],
      loadDuration: json["load_duration"],
      promptEvalCount: json["prompt_eval_count"],
      promptEvalDuration: json["prompt_eval_duration"],
      evalCount: json["eval_count"],
      evalDuration: json["eval_duration"],
    );
  }

  /// Ollama returns `message.tool_calls: [{"function":{"name":…,"arguments":{…}}}]`
  /// with no call id, so one is synthesized per call.
  static List<ToolCall>? _toolCallsFromOllama(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final calls = <ToolCall>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final function = entry['function'];
      if (function is! Map) continue;
      final name = (function['name'] ?? '').toString();
      if (name.isEmpty) continue;
      calls.add(ToolCall(
        id: (entry['id'] ?? 'call_${Uuid().v4()}').toString(),
        name: name,
        arguments: ToolCall.parseArguments(function['arguments']),
      ));
    }
    return calls.isEmpty ? null : calls;
  }

  factory OllamaMessage.fromDatabase(Map<String, dynamic> map) {
    return OllamaMessage(
      map['content'],
      id: map['message_id'],
      role: OllamaMessageRole.fromString(map['role']),
      images: _constructImages(map['images']),
      attachments: Attachment.listFromJson(map['attachments'] as String?),
      toolCalls: () {
        final calls = ToolCall.listFromJson(map['tool_calls'] as String?);
        return calls.isEmpty ? null : calls;
      }(),
      toolCallId: map['tool_call_id'] as String?,
      toolName: map['tool_name'] as String?,
      toolFailed: (map['tool_failed'] as int? ?? 0) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
      model: map['model'],
    );
  }

  Future<Map<String, dynamic>> toJson() async => {
        "model": model,
        "created_at": createdAt.toIso8601String(),
        "message": {
          "role": role.name,
          "content": content,
          "images": await _base64EncodeImages(),
        },
        "done": done,
        "done_reason": doneReason,
        "context":
            context == null ? null : List<dynamic>.from(context!.map((x) => x)),
        "total_duration": totalDuration,
        "load_duration": loadDuration,
        "prompt_eval_count": promptEvalCount,
        "prompt_eval_duration": promptEvalDuration,
        "eval_count": evalCount,
        "eval_duration": evalDuration,
      };

  /// Ollama `/api/chat` message shape. Tool calls ride on the assistant turn
  /// and tool results come back as `role: "tool"` with `tool_name`, which is
  /// how Ollama correlates them (it issues no call ids).
  Future<Map<String, dynamic>> toChatJson() async {
    final out = <String, dynamic>{
      "role": role.name,
      "content": promptContent,
    };

    final encodedImages = await _base64EncodeImages();
    if (encodedImages != null) out["images"] = encodedImages;

    if (hasToolCalls) {
      out["tool_calls"] = toolCalls!
          .map((c) => {
                "function": {
                  "name": c.name,
                  "arguments": c.arguments,
                },
              })
          .toList();
    }
    if (role == OllamaMessageRole.tool && toolName != null) {
      out["tool_name"] = toolName;
    }

    return out;
  }

  Map<String, dynamic> toDatabaseMap() => {
        'message_id': id,
        'content': content,
        'images': _breakImages(images),
        'attachments': Attachment.listToJson(attachments),
        'tool_calls': ToolCall.listToJson(toolCalls),
        'tool_call_id': toolCallId,
        'tool_name': toolName,
        'tool_failed': toolFailed ? 1 : 0,
        'role': role.name,
        'timestamp': createdAt.millisecondsSinceEpoch,
      };

  void updateMetadataFrom(OllamaMessage message) {
    done = message.done;
    doneReason = message.doneReason;
    context = message.context;
    totalDuration = message.totalDuration;
    loadDuration = message.loadDuration;
    promptEvalCount = message.promptEvalCount;
    promptEvalDuration = message.promptEvalDuration;
    evalCount = message.evalCount;
    evalDuration = message.evalDuration;
  }

  Future<List<String>?> _base64EncodeImages() async {
    if (images != null) {
      final encoded = <String>[];
      for (final file in images!) {
        try {
          final bytes = await file.readAsBytes();
          encoded.add(base64Encode(bytes));
        } catch (e) {
          continue;
        }
      }
      return encoded.isNotEmpty ? encoded : null;
    }

    return null;
  }

  static List<File>? _constructImages(String? raw) {
    if (raw != null) {
      final List<dynamic> decoded = jsonDecode(raw);
      return decoded.map((imageRelativePath) {
        return File(path.join(
          PathManager.instance.documentsDirectory.path,
          imageRelativePath,
        ));
      }).toList();
    }

    return null;
  }

  String? _breakImages(List<File>? images) {
    if (images != null) {
      final relativePathImages = images.map((file) {
        return path.relative(
          file.path,
          from: PathManager.instance.documentsDirectory.path,
        );
      }).toList();

      return jsonEncode(relativePathImages);
    }

    return null;
  }
}

enum OllamaMessageRole {
  user,
  assistant,
  system,

  /// The result of a tool the model asked to run. Sent back to the provider as
  /// its own turn so the model can read what the tool returned.
  tool;

  factory OllamaMessageRole.fromString(String role) {
    switch (role) {
      case 'user':
        return OllamaMessageRole.user;
      case 'assistant':
        return OllamaMessageRole.assistant;
      case 'system':
        return OllamaMessageRole.system;
      case 'tool':
        return OllamaMessageRole.tool;
      default:
        throw ArgumentError('Unknown role: $role');
    }
  }
}
