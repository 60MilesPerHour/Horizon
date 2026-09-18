import 'dart:async';
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'package:horizon/Models/chat_tool.dart';
import 'package:horizon/Services/web_search_service.dart';
import 'package:horizon/Utils/horizon_http.dart';

/// Executes the tools Horizon exposes to models.
///
/// This replaces the old `<search>`/`<nosearch>` prompt convention: instead of
/// asking the model to emit a magic tag and hoping it complies, the tools are
/// declared in each provider's native tool protocol and the model decides.
/// A model that doesn't support tools still gets the convention path — see
/// `ChatProvider._prepareSend`.
///
/// Every executor returns text, never throws, and is bounded in size. A tool
/// that fails reports *why* back to the model as its result, so the model can
/// retry with different arguments or tell the user — a thrown exception would
/// abort the whole turn instead.
class ToolService {
  final WebSearchService _webSearch;

  ToolService({required WebSearchService webSearch}) : _webSearch = webSearch;

  /// Hard ceiling on a single tool result, in characters. Large enough for a
  /// substantial article, small enough that three or four fetches can't blow
  /// a 8K-context local model out of the water.
  static const int maxResultChars = 8000;

  static const Duration _fetchTimeout = Duration(seconds: 25);

  // ============================================================
  // Declarations
  // ============================================================

  static const ToolDefinition _webSearchTool = ToolDefinition(
    name: 'web_search',
    description:
        'Search the web for current information: news, recent events, prices, '
        'releases, schedules, sports results, weather, documentation, or any '
        'fact that may have changed recently or that you are not confident '
        'about. Returns a numbered list of results with titles, URLs and short '
        'snippets. Snippets are often truncated — when a result looks like it '
        'holds the answer, call web_fetch on its URL to read the actual page '
        'before answering.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description':
              'The search query. Write it the way you would type it into a '
              'search engine — keywords, not a full sentence.',
        },
      },
      'required': ['query'],
    },
  );

  static const ToolDefinition _webFetchTool = ToolDefinition(
    name: 'web_fetch',
    description:
        'Fetch a web page and return its readable text content with the markup '
        'stripped. Use this to read a page found via web_search, or any URL the '
        'user gives you. Long pages are truncated.',
    parameters: {
      'type': 'object',
      'properties': {
        'url': {
          'type': 'string',
          'description': 'Absolute URL to fetch, including the scheme.',
        },
      },
      'required': ['url'],
    },
  );

  static const ToolDefinition _currentTimeTool = ToolDefinition(
    name: 'current_time',
    description:
        "Get the user's current local date and time. Call this before "
        'answering anything that depends on the present moment — "today", '
        '"this week", someone\'s age, how long until an event, or whether '
        'something has already happened.',
    parameters: {
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  );

  /// The tools available for the current configuration. Web tools are only
  /// offered when a search backend is actually configured — declaring a tool
  /// we can't run invites the model to call it and then apologise, which reads
  /// as a bug to the user.
  List<ToolDefinition> availableTools() {
    final tools = <ToolDefinition>[_currentTimeTool];
    if (_webSearch.isConfigured) {
      tools.insert(0, _webSearchTool);
      tools.insert(1, _webFetchTool);
    } else {
      // web_fetch needs no search key — a URL the user pasted is fetchable on
      // its own, and it's the more useful half of the pair without a backend.
      tools.insert(0, _webFetchTool);
    }
    return tools;
  }

  bool get hasTools => availableTools().isNotEmpty;

  /// Human-readable status label for a call in flight.
  String labelFor(ToolCall call) {
    switch (call.name) {
      case 'web_search':
        final q = call.arguments['query']?.toString().trim() ?? '';
        return q.isEmpty ? 'Searching the web…' : 'Searching for "$q"…';
      case 'web_fetch':
        final url = call.arguments['url']?.toString() ?? '';
        final host = Uri.tryParse(url)?.host ?? '';
        return host.isEmpty ? 'Fetching page…' : 'Reading $host…';
      case 'current_time':
        return 'Checking the time…';
      default:
        return 'Running ${call.name}…';
    }
  }

  // ============================================================
  // Execution
  // ============================================================

  Future<ToolResult> execute(ToolCall call) async {
    try {
      switch (call.name) {
        case 'web_search':
          return await _runWebSearch(call.arguments);
        case 'web_fetch':
          return await _runWebFetch(call.arguments);
        case 'current_time':
          return _runCurrentTime();
        default:
          return ToolResult.error(
            'No tool named "${call.name}" exists. Available tools: '
            '${availableTools().map((t) => t.name).join(', ')}.',
          );
      }
    } on TimeoutException {
      return ToolResult.error(
        '${call.name} timed out. The site may be slow or unreachable — try a '
        'different source.',
      );
    } catch (e) {
      // Tool failures are data, not exceptions: hand the reason to the model.
      return ToolResult.error('${call.name} failed: $e');
    }
  }

  Future<ToolResult> _runWebSearch(Map<String, dynamic> args) async {
    final query = _stringArg(args, const ['query', 'q', 'search', 'value']);
    if (query == null) {
      return ToolResult.error(
        'web_search needs a "query" argument, e.g. {"query": "ollama 0.6 '
        'release notes"}.',
      );
    }
    if (!_webSearch.isConfigured) {
      return ToolResult.error(
        'Web search has no backend configured. Tell the user to set a SerpAPI '
        'key or SearXNG URL in Settings → Web Search.',
      );
    }

    final results = await _webSearch.search(query);
    if (results.isEmpty) {
      return ToolResult(
        'No results for "$query". Try different or broader keywords.',
      );
    }

    final buffer = StringBuffer('Search results for "$query":\n');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      buffer.writeln();
      buffer.writeln('[${i + 1}] ${r.title}');
      buffer.writeln('URL: ${r.url}');
      if (r.snippet.isNotEmpty) buffer.writeln(r.snippet);
    }
    return ToolResult(_truncate(buffer.toString()));
  }

  Future<ToolResult> _runWebFetch(Map<String, dynamic> args) async {
    final raw = _stringArg(args, const ['url', 'link', 'href', 'value']);
    if (raw == null) {
      return ToolResult.error(
        'web_fetch needs a "url" argument, e.g. {"url": '
        '"https://example.com/page"}.',
      );
    }

    var target = raw.trim();
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      target = 'https://$target';
    }
    final uri = Uri.tryParse(target);
    // `Uri.tryParse` is far more permissive than it looks: it happily
    // percent-escapes a sentence into the host component and only blows up
    // later inside the HTTP client, with an error about link-local addresses
    // that tells the model nothing. Check the host really is one.
    if (uri == null || !_isPlausibleHost(uri.host)) {
      return ToolResult.error(
        '"$raw" is not a URL that can be fetched. Pass an absolute URL such '
        'as "https://example.com/page".',
      );
    }

    final response = await HorizonHttp.client.get(uri, headers: {
      // Plenty of sites serve a stub or a challenge page to an unknown agent.
      'User-Agent':
          'Mozilla/5.0 (compatible; Horizon/1.0; +https://github.com/60MilesPerHour/Horizon)',
      'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8',
    }).timeout(_fetchTimeout);

    if (response.statusCode != 200) {
      return ToolResult.error(
        'Fetching $uri returned HTTP ${response.statusCode}. The page may be '
        'gone, private, or blocking automated requests.',
      );
    }

    final contentType =
        (response.headers['content-type'] ?? '').toLowerCase();
    // Decode as UTF-8 regardless of the declared charset; `response.body`
    // falls back to latin-1 when the header omits one, which mangles any
    // page with typographic quotes or accents.
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);

    String text;
    if (contentType.contains('json')) {
      text = body;
    } else if (contentType.contains('html') || body.trimLeft().startsWith('<')) {
      text = _htmlToText(body);
    } else {
      text = body;
    }

    text = text.trim();
    if (text.isEmpty) {
      return ToolResult.error(
        '$uri returned no readable text — it may be a JavaScript-rendered '
        'page, a PDF, or an image.',
      );
    }

    return ToolResult('Content of $uri:\n\n${_truncate(text)}');
  }

  /// A dotted hostname, a bracketed IPv6 literal, or `localhost`. Deliberately
  /// strict: anything with whitespace, a percent escape, or no dot is a model
  /// handing us prose rather than a URL.
  static bool _isPlausibleHost(String host) {
    if (host.isEmpty) return false;
    if (host == 'localhost') return true;
    if (host.startsWith('[') && host.endsWith(']')) return true;
    return RegExp(r'^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
            r'(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$')
        .hasMatch(host);
  }

  ToolResult _runCurrentTime() {
    final now = DateTime.now();
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');

    return ToolResult(
      '${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}, '
      '${now.year} at ${_twoDigit(now.hour)}:${_twoDigit(now.minute)} '
      '(${now.timeZoneName}, UTC$sign$hh:$mm)\n'
      'ISO 8601: ${now.toIso8601String()}',
    );
  }

  static String _twoDigit(int v) => v.toString().padLeft(2, '0');

  /// Pulls a string argument out of [args], accepting any of [keys]. Models —
  /// small local ones especially — routinely rename an argument ("q" for
  /// "query", "link" for "url"), and refusing a call over a synonym wastes a
  /// whole round trip for no reason.
  static String? _stringArg(Map<String, dynamic> args, List<String> keys) {
    for (final key in keys) {
      final value = args[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value != null && value is! Map && value is! List) {
        final s = value.toString().trim();
        if (s.isNotEmpty) return s;
      }
    }
    // Last resort: a single-entry map whose key we didn't recognise.
    if (args.length == 1) {
      final only = args.values.first;
      if (only is String && only.trim().isNotEmpty) return only.trim();
    }
    return null;
  }

  static String _truncate(String text) {
    if (text.length <= maxResultChars) return text;
    return '${text.substring(0, maxResultChars)}\n\n'
        '[Truncated at $maxResultChars characters. Fetch a more specific URL '
        'if you need the rest.]';
  }

  /// Strips a page down to readable text: drops non-content elements, prefers
  /// the main article container when the page marks one, and collapses the
  /// whitespace that HTML indentation leaves behind.
  static String _htmlToText(String source) {
    final document = html_parser.parse(source);

    for (final selector in const [
      'script', 'style', 'noscript', 'template', 'svg', 'iframe',
      'nav', 'header', 'footer', 'aside', 'form', 'button',
    ]) {
      for (final element in document.querySelectorAll(selector)) {
        element.remove();
      }
    }

    // Prefer the semantic content container when the page provides one; a
    // whole-<body> dump is mostly navigation cruft on a modern site.
    dom.Element? root;
    for (final selector in const [
      'article', 'main', '[role="main"]', '#content', '.post', '.article-body',
    ]) {
      final candidate = document.querySelector(selector);
      if (candidate != null && candidate.text.trim().length > 200) {
        root = candidate;
        break;
      }
    }
    root ??= document.body ?? document.documentElement;

    final title = document.querySelector('title')?.text.trim() ?? '';
    final body = _collapseWhitespace(root?.text ?? '');
    return title.isEmpty ? body : '$title\n\n$body';
  }

  static String _collapseWhitespace(String text) {
    return text
        // Tabs and non-breaking spaces read as content to the model otherwise.
        .replaceAll(' ', ' ')
        .replaceAll('\t', ' ')
        // Collapse runs of spaces, but keep line structure.
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r' {2,}'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n')
        // Three or more blank-separated lines add nothing.
        .replaceAll(RegExp(r'\n{3,}'), '\n\n');
  }
}
