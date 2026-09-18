import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Models/attachment.dart';

/// Thrown when a picked file can't be turned into something a model can read.
/// Carries a message meant to be shown to the user verbatim.
class AttachmentException implements Exception {
  final String message;
  const AttachmentException(this.message);
  @override
  String toString() => message;
}

/// Picks documents (PDF / CSV / text / code / JSON), copies them into app
/// storage, and extracts plain text for injection into the prompt.
///
/// Extraction is deliberately client-side and provider-agnostic: the same
/// attachment works on a local Ollama model, on Claude, and on OpenRouter,
/// none of which need to support a document upload API. It also means the
/// user can see exactly what the model was given.
class AttachmentService {
  /// Per-file character budget for extracted text. Roughly 5–6k tokens, which
  /// leaves room for the conversation on an 8K-context local model while still
  /// covering most real documents whole.
  int maxTextChars;

  /// Refuse files larger than this outright — reading a 500 MB log into memory
  /// on a phone is a crash, not a feature.
  static const int maxFileBytes = 64 * 1024 * 1024;

  /// Rows of a CSV to render before summarising the rest.
  static const int maxCsvRows = 200;

  AttachmentService({this.maxTextChars = 20000});

  static const List<String> allowedExtensions = [
    'pdf',
    'csv', 'tsv',
    'txt', 'md', 'markdown', 'log', 'rtf',
    'json', 'jsonl', 'yaml', 'yml', 'toml', 'ini', 'conf',
    'dart', 'py', 'js', 'ts', 'tsx', 'jsx', 'java', 'kt', 'swift',
    'c', 'h', 'cpp', 'hpp', 'cs', 'go', 'rs', 'rb', 'php',
    'sh', 'bash', 'zsh', 'sql', 'html', 'css', 'xml',
  ];

  Future<Directory> getAttachmentsDirectory() async {
    final dir = path.join(
      PathManager.instance.documentsDirectory.path,
      'attachments',
    );
    return await Directory(dir).create(recursive: true);
  }

  /// Opens the system file picker and returns the attachments the user chose.
  /// Returns an empty list when the picker is dismissed. Individual files that
  /// fail to parse are reported via [onError] and skipped, so picking five
  /// files and having one bad PDF still attaches the other four.
  Future<List<Attachment>> pickFiles({
    void Function(String message)? onError,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      // `custom` + an extension list gives a usable picker on desktop; on
      // Android the SAF picker ignores the filter for some providers, which is
      // why unknown extensions still fall through to the text reader.
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return const [];

    final out = <Attachment>[];
    for (final picked in result.files) {
      final sourcePath = picked.path;
      if (sourcePath == null) {
        onError?.call('Could not read ${picked.name}.');
        continue;
      }
      try {
        out.add(await ingest(File(sourcePath), displayName: picked.name));
      } on AttachmentException catch (e) {
        onError?.call(e.message);
      } catch (e) {
        onError?.call('Could not attach ${picked.name}: $e');
      }
    }
    return out;
  }

  /// Copies [source] into app storage and extracts its text.
  Future<Attachment> ingest(File source, {String? displayName}) async {
    final name = displayName ?? path.basename(source.path);

    if (!await source.exists()) {
      throw AttachmentException('$name no longer exists on disk.');
    }
    final sizeBytes = await source.length();
    if (sizeBytes == 0) {
      throw AttachmentException('$name is empty.');
    }
    if (sizeBytes > maxFileBytes) {
      throw AttachmentException(
        '$name is ${(sizeBytes / (1024 * 1024)).round()} MB — too large to '
        'attach (limit ${maxFileBytes ~/ (1024 * 1024)} MB).',
      );
    }

    final kind = AttachmentKind.fromExtension(name);
    final bytes = await source.readAsBytes();

    final _Extracted extracted;
    switch (kind) {
      case AttachmentKind.pdf:
        extracted = _extractPdf(bytes, name);
      case AttachmentKind.csv:
        extracted = _extractCsv(_decodeText(bytes, name));
      case AttachmentKind.json:
      case AttachmentKind.code:
      case AttachmentKind.text:
        extracted = _extractPlainText(_decodeText(bytes, name));
    }

    if (extracted.text.trim().isEmpty) {
      throw AttachmentException(
        kind == AttachmentKind.pdf
            ? '$name has no extractable text — it looks like a scanned image. '
                'Attach it as an image instead so a vision model can read it.'
            : '$name contains no readable text.',
      );
    }

    // Copy into app storage so the attachment survives the source file being
    // moved or deleted, and so the cleanup trigger can reclaim it later.
    final dir = await getAttachmentsDirectory();
    final stored = File(path.join(
      dir.path,
      '${DateTime.now().microsecondsSinceEpoch}_${_sanitizeFilename(name)}',
    ));
    await stored.writeAsBytes(bytes);

    return Attachment(
      file: stored,
      name: name,
      kind: kind,
      text: extracted.text,
      sizeBytes: sizeBytes,
      pageCount: extracted.pageCount,
      truncated: extracted.truncated,
    );
  }

  Future<void> delete(Attachment attachment) async {
    try {
      if (await attachment.file.exists()) await attachment.file.delete();
    } catch (_) {
      // Best-effort cleanup; a leftover file is not worth surfacing.
    }
  }

  Future<void> deleteAll(List<Attachment> attachments) async {
    for (final a in attachments) {
      await delete(a);
    }
  }

  // ============================================================
  // Extraction
  // ============================================================

  /// Decodes bytes as UTF-8, falling back to latin-1 so a Windows-encoded log
  /// still reads rather than throwing. Rejects anything that looks binary —
  /// a mislabelled .txt that's really a zip would otherwise fill the context
  /// with mojibake.
  String _decodeText(List<int> bytes, String name) {
    final sample = bytes.take(4096);
    final nullBytes = sample.where((b) => b == 0).length;
    if (nullBytes > 1) {
      throw AttachmentException(
        '$name looks like a binary file, not text.',
      );
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }

  _Extracted _extractPlainText(String content) {
    if (content.length <= maxTextChars) {
      return _Extracted(content);
    }
    return _Extracted(
      content.substring(0, maxTextChars),
      truncated: true,
    );
  }

  /// Renders a CSV/TSV as a header plus bounded rows. A raw dump of a
  /// 40,000-row export is both useless to the model and enough to evict the
  /// rest of the conversation from the context window, so the tail becomes a
  /// row count instead.
  _Extracted _extractCsv(String content) {
    final lines = const LineSplitter()
        .convert(content)
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return _Extracted('');

    final kept = lines.take(maxCsvRows + 1).toList();
    final buffer = StringBuffer(kept.join('\n'));
    var truncated = false;

    if (lines.length > kept.length) {
      truncated = true;
      buffer.write(
        '\n\n[${lines.length - kept.length} further rows omitted; '
        '${lines.length - 1} data rows total.]',
      );
    }

    var text = buffer.toString();
    if (text.length > maxTextChars) {
      text = '${text.substring(0, maxTextChars)}\n[Truncated.]';
      truncated = true;
    }
    return _Extracted(text, truncated: truncated);
  }

  /// Extracts PDF text page by page so a huge document stops costing time as
  /// soon as the budget is spent, instead of extracting 900 pages and then
  /// throwing away 890 of them.
  _Extracted _extractPdf(List<int> bytes, String name) {
    final PdfDocument document;
    try {
      document = PdfDocument(inputBytes: bytes);
    } catch (_) {
      throw AttachmentException(
        '$name could not be opened as a PDF (it may be corrupt or password '
        'protected).',
      );
    }

    try {
      final pageCount = document.pages.count;
      final extractor = PdfTextExtractor(document);
      final buffer = StringBuffer();
      var truncated = false;
      var lastPage = 0;

      for (var i = 0; i < pageCount; i++) {
        String pageText;
        try {
          pageText = extractor.extractText(startPageIndex: i, endPageIndex: i);
        } catch (_) {
          // A single malformed page shouldn't lose the whole document.
          continue;
        }
        pageText = pageText.trim();
        lastPage = i + 1;
        if (pageText.isEmpty) continue;

        if (buffer.length + pageText.length > maxTextChars) {
          final remaining = maxTextChars - buffer.length;
          if (remaining > 200) {
            buffer.writeln('[Page ${i + 1}]');
            buffer.writeln(pageText.substring(0, remaining));
          }
          truncated = true;
          break;
        }

        if (pageCount > 1) buffer.writeln('[Page ${i + 1}]');
        buffer.writeln(pageText);
        buffer.writeln();
      }

      if (truncated) {
        buffer.write(
          '\n[Extraction stopped at page $lastPage of $pageCount to stay '
          'within the context budget.]',
        );
      }

      return _Extracted(
        buffer.toString().trim(),
        pageCount: pageCount,
        truncated: truncated,
      );
    } finally {
      document.dispose();
    }
  }

  static String _sanitizeFilename(String name) {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return safe.length > 80 ? safe.substring(safe.length - 80) : safe;
  }
}

class _Extracted {
  final String text;
  final int? pageCount;
  final bool truncated;

  const _Extracted(this.text, {this.pageCount, this.truncated = false});
}
