import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'package:horizon/Constants/constants.dart';

/// What kind of document an attachment is, which decides how its text was
/// extracted and how it's labelled in the transcript.
enum AttachmentKind {
  pdf,
  csv,
  json,
  code,
  text;

  static AttachmentKind fromExtension(String filename) {
    switch (path.extension(filename).toLowerCase()) {
      case '.pdf':
        return AttachmentKind.pdf;
      case '.csv':
      case '.tsv':
        return AttachmentKind.csv;
      case '.json':
      case '.jsonl':
      case '.yaml':
      case '.yml':
      case '.toml':
        return AttachmentKind.json;
      case '.dart':
      case '.py':
      case '.js':
      case '.ts':
      case '.tsx':
      case '.jsx':
      case '.java':
      case '.kt':
      case '.swift':
      case '.c':
      case '.h':
      case '.cpp':
      case '.hpp':
      case '.cs':
      case '.go':
      case '.rs':
      case '.rb':
      case '.php':
      case '.sh':
      case '.bash':
      case '.zsh':
      case '.sql':
      case '.html':
      case '.css':
      case '.xml':
        return AttachmentKind.code;
      default:
        return AttachmentKind.text;
    }
  }

  static AttachmentKind fromName(String? name) {
    return AttachmentKind.values.firstWhere(
      (k) => k.name == name,
      orElse: () => AttachmentKind.text,
    );
  }

  String get label {
    switch (this) {
      case AttachmentKind.pdf:
        return 'PDF';
      case AttachmentKind.csv:
        return 'Spreadsheet';
      case AttachmentKind.json:
        return 'Data';
      case AttachmentKind.code:
        return 'Code';
      case AttachmentKind.text:
        return 'Document';
    }
  }
}

/// A non-image file the user attached to a message.
///
/// The extracted text is persisted alongside the path rather than re-derived
/// on load. Two reasons: PDF extraction is slow enough to stall a chat open,
/// and re-extracting means a later parser change could silently alter what a
/// past conversation claims the model was shown.
class Attachment {
  /// Where the copied file lives on disk. Stored relative to the documents
  /// directory so the row survives an app-container path change (iOS/Android
  /// both move these between installs).
  final File file;

  /// Original filename as the user picked it, shown in the UI and given to
  /// the model.
  final String name;

  final AttachmentKind kind;

  /// Plain-text rendering of the file that gets injected into the prompt.
  final String text;

  /// Bytes on disk, for the UI subtitle.
  final int sizeBytes;

  /// Page count for PDFs, null otherwise.
  final int? pageCount;

  /// True when [text] is a shortened rendering of a larger file.
  final bool truncated;

  const Attachment({
    required this.file,
    required this.name,
    required this.kind,
    required this.text,
    required this.sizeBytes,
    this.pageCount,
    this.truncated = false,
  });

  /// The block handed to the model. Delimited and labelled so the model can
  /// tell file content apart from the user's own words — unlabelled pasted
  /// text is the single biggest cause of a model answering *about* the
  /// delimiter instead of the document.
  String toPromptBlock() {
    final header = StringBuffer('--- Attached file: $name');
    if (pageCount != null) header.write(' ($pageCount pages)');
    if (truncated) header.write(' — truncated');
    header.write(' ---');
    return '${header.toString()}\n$text\n--- End of $name ---';
  }

  String get sizeLabel {
    if (sizeBytes >= 1024 * 1024) {
      return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (sizeBytes >= 1024) return '${(sizeBytes / 1024).round()} KB';
    return '$sizeBytes B';
  }

  String get subtitle {
    final parts = <String>[kind.label, sizeLabel];
    if (pageCount != null) parts.add('$pageCount pages');
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => {
        'path': path.relative(
          file.path,
          from: PathManager.instance.documentsDirectory.path,
        ),
        'name': name,
        'kind': kind.name,
        'text': text,
        'size': sizeBytes,
        if (pageCount != null) 'pages': pageCount,
        if (truncated) 'truncated': true,
      };

  factory Attachment.fromJson(Map<String, dynamic> map) => Attachment(
        file: File(path.join(
          PathManager.instance.documentsDirectory.path,
          (map['path'] ?? '').toString(),
        )),
        name: (map['name'] ?? 'attachment').toString(),
        kind: AttachmentKind.fromName(map['kind'] as String?),
        text: (map['text'] ?? '').toString(),
        sizeBytes: (map['size'] as num?)?.toInt() ?? 0,
        pageCount: (map['pages'] as num?)?.toInt(),
        truncated: map['truncated'] == true,
      );

  static String? listToJson(List<Attachment>? attachments) {
    if (attachments == null || attachments.isEmpty) return null;
    return jsonEncode(attachments.map((a) => a.toJson()).toList());
  }

  static List<Attachment>? listFromJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      final out = decoded
          .whereType<Map>()
          .map((m) => Attachment.fromJson(
              m.map((k, v) => MapEntry(k.toString(), v))))
          .toList();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }
}
