import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:horizon/Constants/constants.dart';
import 'package:horizon/Extensions/markdown_stylesheet_extension.dart';

/// Parses `<artifact title="…" type="…" lang="…"> … </artifact>` blocks out of
/// a model reply. Modeled on [ThinkBlockSyntax]: it consumes everything between
/// the open/close tags and hands it off to [ArtifactBlockBuilder] as a single
/// element, with the tag's attributes preserved on the element.
class ArtifactBlockSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp(r'^<artifact(\s[^>]*)?>\s*$');

  @override
  bool canEndBlock(md.BlockParser parser) => false;

  const ArtifactBlockSyntax();

  static String? _attr(String line, String name) {
    final match = RegExp('$name="([^"]*)"').firstMatch(line);
    return match?.group(1);
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final opening = parser.current.content;
    parser.advance(); // past the opening <artifact …> tag

    final lines = <String>[];
    while (!parser.isDone) {
      if (parser.current.content.trimRight() == '</artifact>') {
        parser.advance(); // past the closing tag
        break;
      }
      lines.add(parser.current.content);
      parser.advance();
    }

    final content = lines.join('\n');
    final element = md.Element.text(ArtifactConstants.tag, content);
    element.attributes['title'] = _attr(opening, 'title') ?? 'Artifact';
    element.attributes['atype'] = _attr(opening, 'type') ?? 'markdown';
    element.attributes['lang'] = _attr(opening, 'lang') ?? '';
    return md.Element('pre', [element]);
  }
}

class ArtifactBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return ArtifactCard(
      title: element.attributes['title'] ?? 'Artifact',
      type: element.attributes['atype'] ?? 'markdown',
      lang: element.attributes['lang'] ?? '',
      content: element.textContent,
    );
  }
}

/// Collapsed in-bubble representation of an artifact. Tapping opens the viewer.
class ArtifactCard extends StatelessWidget {
  final String title;
  final String type;
  final String lang;
  final String content;

  const ArtifactCard({
    super.key,
    required this.title,
    required this.type,
    required this.lang,
    required this.content,
  });

  bool get _isCode => type == 'code';

  String get _subtitle {
    final lines = content.split('\n').length;
    final kind = _isCode ? (lang.isEmpty ? 'Code' : lang) : 'Document';
    return '$kind · $lines lines';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12.0),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ArtifactViewerPage(
                title: title,
                type: type,
                lang: lang,
                content: content,
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              children: [
                Icon(
                  _isCode ? Icons.code_rounded : Icons.description_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        _subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.open_in_full_rounded,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen artifact viewer with Preview / Source tabs, copy, and export.
/// A plain route (rather than a split pane) so it behaves the same on phone
/// and desktop for this first cut.
class ArtifactViewerPage extends StatelessWidget {
  final String title;
  final String type;
  final String lang;
  final String content;

  const ArtifactViewerPage({
    super.key,
    required this.title,
    required this.type,
    required this.lang,
    required this.content,
  });

  bool get _isCode => type == 'code';

  String get _fileExtension {
    if (!_isCode) return 'md';
    const map = {
      'dart': 'dart',
      'python': 'py',
      'py': 'py',
      'javascript': 'js',
      'js': 'js',
      'typescript': 'ts',
      'ts': 'ts',
      'java': 'java',
      'kotlin': 'kt',
      'swift': 'swift',
      'go': 'go',
      'rust': 'rs',
      'rs': 'rs',
      'c': 'c',
      'cpp': 'cpp',
      'csharp': 'cs',
      'cs': 'cs',
      'html': 'html',
      'css': 'css',
      'json': 'json',
      'yaml': 'yaml',
      'sh': 'sh',
      'bash': 'sh',
      'sql': 'sql',
    };
    return map[lang.toLowerCase()] ?? 'txt';
  }

  String get _safeFilename {
    final base = title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim();
    final name = base.isEmpty ? 'artifact' : base.replaceAll(' ', '_');
    return '$name.$_fileExtension';
  }

  /// Markdown source used to render the Preview tab. For code we wrap the raw
  /// content in a fenced block so it gets the monospace + code styling; for a
  /// document the content is already markdown.
  String get _previewMarkdown =>
      _isCode ? '```$lang\n$content\n```' : content;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: content));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Artifact copied')),
      );
    }
  }

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$_safeFilename');
      await file.writeAsString(content);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path, name: _safeFilename)], subject: title),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeStyle = GoogleFonts.sourceCodePro();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () => _copy(context),
            ),
            IconButton(
              tooltip: 'Export',
              icon: const Icon(Icons.ios_share_outlined),
              onPressed: () => _export(context),
            ),
          ],
          bottom: const TabBar(
            tabs: [Tab(text: 'Preview'), Tab(text: 'Source')],
          ),
        ),
        body: TabBarView(
          children: [
            // Preview
            Markdown(
              data: _previewMarkdown,
              selectable: true,
              padding: const EdgeInsets.all(16),
              styleSheet: context.markdownStyleSheet.copyWith(code: codeStyle),
            ),
            // Source
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                content,
                style: codeStyle.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
