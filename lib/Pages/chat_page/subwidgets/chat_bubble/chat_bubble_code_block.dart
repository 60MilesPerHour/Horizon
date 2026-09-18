import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_highlight/flutter_highlight.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;

/// Renders fenced code blocks: a header strip with the language and a copy
/// button, then syntax-highlighted, horizontally scrollable source.
///
/// Registered against `pre` rather than `code` deliberately — `pre` only ever
/// wraps a fenced block, so inline `code` spans keep the plain monospace
/// treatment from the markdown stylesheet instead of being boxed and
/// highlighted mid-sentence.
class CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent;
    if (code.trim().isEmpty) return null;

    return _CodeBlock(
      code: code.endsWith('\n') ? code.substring(0, code.length - 1) : code,
      language: _languageOf(element),
    );
  }

  /// Markdown emits the fence info string as a class on the inner `code`
  /// element (`class="language-dart"`). Returns null for a bare fence.
  static String? _languageOf(md.Element element) {
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is! md.Element) continue;
      final classes = child.attributes['class'];
      if (classes == null) continue;
      for (final entry in classes.split(' ')) {
        if (entry.startsWith('language-')) {
          final name = entry.substring('language-'.length).trim();
          if (name.isNotEmpty) return name;
        }
      }
    }
    return null;
  }
}

class _CodeBlock extends StatefulWidget {
  final String code;
  final String? language;

  const _CodeBlock({required this.code, this.language});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1600));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    // The bundled themes paint their own background on the `root` key, which
    // fights the app's surface colours (and the OLED-black dark theme in
    // particular). Drop it and let the container own the background.
    final highlightTheme = {
      ...(isDark ? atomOneDarkTheme : atomOneLightTheme),
    }..remove('root');

    final background = isDark
        ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45)
        : theme.colorScheme.surfaceContainer;

    return Container(
      // Full bleed inside the bubble; the bubble supplies the outer padding.
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: theme.colorScheme.outlineVariant, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(theme),
          // Code lines shouldn't wrap — wrapping a long line silently changes
          // what the code looks like. Scroll it instead.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12.0, 4.0, 12.0, 12.0),
            child: HighlightView(
              widget.code,
              // Unknown or absent languages fall through to plaintext in the
              // highlighter, so no allow-list check is needed here.
              language: widget.language ?? 'plaintext',
              theme: highlightTheme,
              textStyle: GoogleFonts.sourceCodePro(
                fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) - 1,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.only(left: 12.0, right: 4.0),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.language?.toLowerCase() ?? 'code',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.4,
              ),
            ),
          ),
          IconButton(
            onPressed: _copied ? null : _copy,
            visualDensity: VisualDensity.compact,
            iconSize: 18.0,
            tooltip: 'Copy code',
            icon: Icon(
              _copied ? Icons.check : Icons.copy_outlined,
              color: _copied
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
