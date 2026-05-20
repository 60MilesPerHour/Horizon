import 'dart:convert';

import 'package:horizon/Models/ollama_chat.dart';
import 'package:horizon/Models/ollama_message.dart';

/// Output format for chat exports.
enum ChatExportFormat {
  markdown,
  text;

  /// File extension (no leading dot) for this format.
  String get extension => switch (this) {
        ChatExportFormat.markdown => 'md',
        ChatExportFormat.text => 'txt',
      };

  /// MIME type for sharing.
  String get mimeType => switch (this) {
        ChatExportFormat.markdown => 'text/markdown',
        ChatExportFormat.text => 'text/plain',
      };
}

/// Snapshot of a parsed chat export — everything the chat provider needs to
/// re-create the conversation in the database.
class ImportedChat {
  final OllamaChat chat;
  final List<OllamaMessage> messages;

  const ImportedChat({required this.chat, required this.messages});
}

/// Round-trip serialisation for Horizon chats.
///
/// Markdown is the preferred format — it embeds a JSON-in-HTML-comment block
/// at the top with all the metadata, then renders the conversation as plain
/// Markdown so the export reads cleanly in any viewer (GitHub, Obsidian, a
/// browser, whatever). The plain-text export is the same shape minus the
/// Markdown niceties — useful when you just want a copy-pasteable log.
///
/// `parseImport` accepts either format. The metadata block is required for a
/// faithful restore; without it we fall back to sane defaults so a hand-edited
/// file still imports as a usable chat.
class ChatExportService {
  /// Current schema version. Bump when the metadata shape changes in a way
  /// that older importers can't tolerate.
  static const int schemaVersion = 1;

  // ---------- Export ----------

  /// Build a Markdown export with embedded metadata header.
  String exportToMarkdown(OllamaChat chat, List<OllamaMessage> messages) {
    final buffer = StringBuffer();
    buffer.writeln('<!--');
    buffer.writeln(_encodeMetadata(chat));
    buffer.writeln('-->');
    buffer.writeln();
    buffer.writeln('# ${chat.title}');
    buffer.writeln();
    buffer.writeln(
      '> Exported from Horizon · model `${chat.model}` · provider `${chat.provider}`',
    );
    buffer.writeln();

    if (chat.systemPrompt != null && chat.systemPrompt!.isNotEmpty) {
      buffer.writeln('## System');
      buffer.writeln();
      buffer.writeln(chat.systemPrompt);
      buffer.writeln();
    }

    for (final m in messages) {
      buffer.writeln('## ${_roleHeader(m.role)} · ${_formatTimestamp(m.createdAt)}');
      buffer.writeln();
      buffer.writeln(m.content);
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// Build a plain-text export. Same metadata header (now plain comment), no
  /// Markdown formatting, just role/timestamp section markers.
  String exportToText(OllamaChat chat, List<OllamaMessage> messages) {
    final buffer = StringBuffer();
    buffer.writeln('# HORIZON EXPORT');
    buffer.writeln('# ${_encodeMetadata(chat)}');
    buffer.writeln("# (Do not remove the line above — it's used to restore the chat.)");
    buffer.writeln();
    buffer.writeln(chat.title);
    buffer.writeln('=' * chat.title.length);
    buffer.writeln('Exported from Horizon · model ${chat.model} · provider ${chat.provider}');
    buffer.writeln();

    if (chat.systemPrompt != null && chat.systemPrompt!.isNotEmpty) {
      buffer.writeln('--- SYSTEM ---');
      buffer.writeln(chat.systemPrompt);
      buffer.writeln();
    }

    for (final m in messages) {
      buffer.writeln(
        '--- ${_roleHeader(m.role).toUpperCase()} · ${_formatTimestamp(m.createdAt)} ---',
      );
      buffer.writeln(m.content);
      buffer.writeln();
    }

    return buffer.toString();
  }

  // ---------- Import ----------

  /// Parse a Markdown or text export back into a chat + messages.
  ///
  /// If the metadata header is present, it's the source of truth for model,
  /// provider, title, system prompt, and chat options. If it's missing, we
  /// construct a reasonable placeholder chat (provider: ollama, model: empty)
  /// so the user can fix it up in Configure Chat after import.
  ImportedChat parseImport(String content) {
    final metadata = _extractMetadata(content);
    final body = _stripMetadataBlock(content);

    final chat = OllamaChat(
      // Always mint a fresh ID on import so we never collide with an existing chat.
      title: (metadata['title'] as String?) ?? 'Imported chat',
      model: (metadata['model'] as String?) ?? '',
      systemPrompt: metadata['system_prompt'] as String?,
      provider: (metadata['provider'] as String?) ?? 'ollama',
      options: metadata['options'] is Map
          ? OllamaChatOptions.fromMap(
              (metadata['options'] as Map).cast<String, dynamic>(),
            )
          : null,
    );

    final messages = _parseMessages(body);
    return ImportedChat(chat: chat, messages: messages);
  }

  // ---------- Internals ----------

  String _encodeMetadata(OllamaChat chat) {
    return json.encode({
      'horizon_export': schemaVersion,
      'title': chat.title,
      'model': chat.model,
      'provider': chat.provider,
      'system_prompt': chat.systemPrompt,
      'options': _optionsAsMap(chat.options),
      'exported_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Re-derive the options map. OllamaChatOptions exposes toJson (full) and
  /// toMap (API-options only, no `think`); we want everything for round-trip,
  /// so we read its toJson and re-decode to keep this side-effect-free.
  Map<String, dynamic> _optionsAsMap(OllamaChatOptions options) {
    return json.decode(options.toJson()) as Map<String, dynamic>;
  }

  /// Extract the metadata JSON object regardless of which format was used.
  /// Returns an empty map when no header is found.
  Map<String, dynamic> _extractMetadata(String content) {
    // Markdown: <!-- {...} --> at the very top.
    final mdRegex = RegExp(r'<!--\s*(\{.*?\})\s*-->', dotAll: true);
    final mdMatch = mdRegex.firstMatch(content);
    if (mdMatch != null) {
      return _safeJson(mdMatch.group(1)!);
    }

    // Plain-text: `# {...}` on a leading comment line.
    final txtRegex = RegExp(r'^\s*#\s*(\{.*?\})\s*$', multiLine: true);
    final txtMatch = txtRegex.firstMatch(content);
    if (txtMatch != null) {
      return _safeJson(txtMatch.group(1)!);
    }

    return const {};
  }

  Map<String, dynamic> _safeJson(String raw) {
    try {
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // Fall through to empty map — better to import a malformed chat with
      // placeholder metadata than to fail outright.
    }
    return const {};
  }

  /// Strip the metadata header so the body parser doesn't see it as content.
  String _stripMetadataBlock(String content) {
    return content
        .replaceFirst(
          RegExp(r'<!--\s*\{.*?\}\s*-->\s*', dotAll: true),
          '',
        )
        .replaceFirst(
          RegExp(r'^#\s*HORIZON EXPORT\s*\n', multiLine: true),
          '',
        )
        .replaceFirst(
          RegExp(r'^#\s*\{.*?\}\s*\n', multiLine: true),
          '',
        )
        .replaceFirst(
          RegExp(r'^#\s*\(Do not remove.*\)\s*\n', multiLine: true),
          '',
        );
  }

  /// Split the body into per-role messages.
  ///
  /// Recognises:
  ///   - Markdown headers:  `## User · <ts>`, `## Assistant · <ts>`, `## System`
  ///   - Text dividers:     `--- USER · <ts> ---`, `--- ASSISTANT · <ts> ---`, etc.
  ///
  /// Anything before the first recognised header is discarded (title /
  /// quote line / blank lines from the export preamble).
  List<OllamaMessage> _parseMessages(String body) {
    final headerRegex = RegExp(
      r'^(?:##\s+|\-\-\-\s+)(System|User|Assistant)(?:\s+·\s+(.+?))?(?:\s+\-\-\-)?$',
      multiLine: true,
      caseSensitive: false,
    );

    final matches = headerRegex.allMatches(body).toList();
    if (matches.isEmpty) return const [];

    final messages = <OllamaMessage>[];
    for (int i = 0; i < matches.length; i++) {
      final match = matches[i];
      final roleLabel = match.group(1)!.toLowerCase();
      final timestamp = match.group(2);
      final contentStart = match.end;
      final contentEnd =
          i + 1 < matches.length ? matches[i + 1].start : body.length;
      final raw = body.substring(contentStart, contentEnd).trim();
      if (raw.isEmpty) continue;

      final role = _roleFromLabel(roleLabel);
      // System "messages" come from the optional system block in the export.
      // Treat them as the chat's system prompt rather than a chat message —
      // the importer surfaces that through OllamaChat.systemPrompt instead.
      if (role == OllamaMessageRole.system) continue;

      messages.add(
        OllamaMessage(
          raw,
          role: role,
          createdAt: _tryParseTimestamp(timestamp) ?? DateTime.now(),
        ),
      );
    }
    return messages;
  }

  String _roleHeader(OllamaMessageRole role) {
    switch (role) {
      case OllamaMessageRole.user:
        return 'User';
      case OllamaMessageRole.assistant:
        return 'Assistant';
      case OllamaMessageRole.system:
        return 'System';
    }
  }

  OllamaMessageRole _roleFromLabel(String label) {
    switch (label) {
      case 'assistant':
        return OllamaMessageRole.assistant;
      case 'system':
        return OllamaMessageRole.system;
      default:
        return OllamaMessageRole.user;
    }
  }

  String _formatTimestamp(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  DateTime? _tryParseTimestamp(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    final iso = DateTime.tryParse(trimmed);
    if (iso != null) return iso;
    // Our exporter format: "YYYY-MM-DD HH:MM" (local time, no zone).
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\s+(\d{2}):(\d{2})$').firstMatch(trimmed);
    if (m != null) {
      return DateTime(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
      );
    }
    return null;
  }
}
