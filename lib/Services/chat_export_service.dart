import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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
    // Normalise line endings so every regex below can assume `\n`.
    content = content.replaceAll('\r\n', '\n');
    final metadata = _extractMetadata(content);
    if (metadata.isEmpty && _looksLikeReinsExport(content)) {
      return _parseReinsExport(content);
    }
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

  // ---------- Reins import ----------

  static final _reinsRoleRegex = RegExp(
    r'^\*\*(User|Assistant|System)\*\*[ \t]*$',
    multiLine: true,
  );
  static final _reinsModelRegex = RegExp(
    r'^Model:\s*(.+?)\s*·\s*Exported:\s*(.+?)\s*$',
    multiLine: true,
  );

  /// Reins' Markdown export has no metadata block — just a `# Title`, a
  /// `Model: x · Exported: <date> · <time>` line, then `**User**` /
  /// `**Assistant**` blocks separated by `---` rules. No per-message
  /// timestamps.
  bool _looksLikeReinsExport(String content) =>
      _reinsModelRegex.hasMatch(content) && _reinsRoleRegex.hasMatch(content);

  ImportedChat _parseReinsExport(String content) {
    final title = RegExp(r'^#\s+(.+?)\s*$', multiLine: true)
        .firstMatch(content)
        ?.group(1);
    final modelMatch = _reinsModelRegex.firstMatch(content);
    final model = modelMatch?.group(1) ?? '';
    final exportedAt =
        _tryParseReinsDate(modelMatch?.group(2)) ?? DateTime.now();

    // A role marker only counts when it opens the body or follows a `---`
    // rule, so a message that happens to contain a bare `**User**` line
    // doesn't get split in two.
    final searchFrom = modelMatch?.end ?? 0;
    final markers = _reinsRoleRegex.allMatches(content, searchFrom).where((m) {
      final before = content.substring(searchFrom, m.start).trimRight();
      return before.isEmpty || before.endsWith('\n---') || before == '---';
    }).toList();

    final messages = <OllamaMessage>[];
    String? systemPrompt;
    for (int i = 0; i < markers.length; i++) {
      final end = i + 1 < markers.length ? markers[i + 1].start : content.length;
      final raw = content
          .substring(markers[i].end, end)
          .trim()
          .replaceFirst(RegExp(r'\n*---$'), '')
          .trim();
      if (raw.isEmpty) continue;

      final role = _roleFromLabel(markers[i].group(1)!.toLowerCase());
      if (role == OllamaMessageRole.system) {
        systemPrompt ??= raw;
        continue;
      }
      // Messages are ordered by timestamp, so give each a distinct one
      // counting back from the export time.
      messages.add(OllamaMessage(raw, role: role, createdAt: exportedAt));
    }
    for (int i = 0; i < messages.length; i++) {
      messages[i].createdAt =
          exportedAt.subtract(Duration(seconds: messages.length - i));
    }

    return ImportedChat(
      chat: OllamaChat(
        title: title ?? 'Imported chat',
        model: model,
        systemPrompt: systemPrompt,
        provider: 'ollama',
      ),
      messages: messages,
    );
  }

  /// True when [bytes] start with a zip signature — how a `.reins` archive
  /// is told apart from a Markdown/text export.
  static bool isZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04;

  /// Parse a Reins `.reins` archive: a zip holding a single `chat.json` of
  /// `{version, exportedAt, chat: {model, chat_title, system_prompt,
  /// options}, messages: [{role, content, timestamp}]}`. `options` is a JSON
  /// string, and `timestamp` is epoch milliseconds.
  ImportedChat parseReinsArchive(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.files.firstWhere(
      (f) => f.isFile && f.name.split('/').last == 'chat.json',
      orElse: () => throw const FormatException('No chat.json in .reins file'),
    );
    final root = json.decode(utf8.decode(entry.content as List<int>));
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Malformed chat.json');
    }

    final chatMap = (root['chat'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rawOptions = chatMap['options'];
    final options = switch (rawOptions) {
      String s when s.isNotEmpty => _safeJson(s),
      Map m => m.cast<String, dynamic>(),
      _ => const <String, dynamic>{},
    };
    final exportedAt =
        DateTime.tryParse(root['exportedAt'] as String? ?? '') ?? DateTime.now();

    final messages = <OllamaMessage>[];
    String? systemPrompt = chatMap['system_prompt'] as String?;
    for (final raw in (root['messages'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final content = raw['content'] as String? ?? '';
      if (content.trim().isEmpty) continue;
      final role = _roleFromLabel((raw['role'] as String? ?? '').toLowerCase());
      if (role == OllamaMessageRole.system) {
        systemPrompt ??= content;
        continue;
      }
      final ts = raw['timestamp'];
      messages.add(OllamaMessage(
        content,
        role: role,
        createdAt: ts is int
            ? DateTime.fromMillisecondsSinceEpoch(ts)
            : exportedAt.add(Duration(milliseconds: messages.length)),
      ));
    }

    return ImportedChat(
      chat: OllamaChat(
        title: (chatMap['chat_title'] as String?) ?? 'Imported chat',
        model: (chatMap['model'] as String?) ?? '',
        systemPrompt:
            (systemPrompt?.isEmpty ?? true) ? null : systemPrompt,
        provider: 'ollama',
        options: options.isEmpty ? null : OllamaChatOptions.fromMap(options),
      ),
      messages: messages,
    );
  }

  /// "October 1, 2026 · 9:27 AM" → local DateTime.
  DateTime? _tryParseReinsDate(String? raw) {
    if (raw == null) return null;
    final m = RegExp(
      r'^([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})(?:\s*·\s*(\d{1,2}):(\d{2})\s*([AaPp][Mm])?)?',
    ).firstMatch(raw.trim());
    if (m == null) return null;
    const months = [
      'january', 'february', 'march', 'april', 'may', 'june', 'july',
      'august', 'september', 'october', 'november', 'december',
    ];
    final month = months.indexOf(m.group(1)!.toLowerCase()) + 1;
    if (month == 0) return null;
    var hour = int.tryParse(m.group(4) ?? '') ?? 0;
    final ampm = m.group(6)?.toLowerCase();
    if (ampm == 'pm' && hour < 12) hour += 12;
    if (ampm == 'am' && hour == 12) hour = 0;
    return DateTime(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(2)!),
      hour,
      int.tryParse(m.group(5) ?? '') ?? 0,
    );
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
      case OllamaMessageRole.tool:
        return 'Tool';
    }
  }

  OllamaMessageRole _roleFromLabel(String label) {
    switch (label) {
      case 'assistant':
        return OllamaMessageRole.assistant;
      case 'system':
        return OllamaMessageRole.system;
      case 'tool':
        return OllamaMessageRole.tool;
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
