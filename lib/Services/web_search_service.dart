import 'dart:convert';

import 'package:http/http.dart' as http;

/// Which search backend the web-search feature talks to.
///
/// `serpapi` is the default for the chat app: it's a hosted API reachable
/// from any device (including the phone build) with just a key, so it doesn't
/// need a route to the LAN. `searxng` points at a self-hosted SearXNG instance
/// (e.g. the sibling Horizon Search deployment) for users who'd rather keep
/// queries on their own box — but that only works where the instance is
/// reachable.
enum WebSearchBackend {
  off,
  serpapi,
  searxng;

  static WebSearchBackend fromString(String? value) {
    switch (value) {
      case 'serpapi':
        return WebSearchBackend.serpapi;
      case 'searxng':
        return WebSearchBackend.searxng;
      default:
        return WebSearchBackend.off;
    }
  }
}

/// One search hit, normalised across backends.
class WebSearchResult {
  final String title;
  final String url;
  final String snippet;

  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });
}

/// Fetches web results and turns them into a context block that gets injected
/// into the outgoing prompt. Deliberately backend-agnostic and provider-
/// agnostic: it produces plain text, so the same path works for Ollama,
/// Claude, OpenAI, and Gemini without any per-provider tool protocol.
///
/// Config (backend, SerpAPI key, SearXNG URL) is held in memory and loaded at
/// boot, mirroring the cloud chat services. The settings UI updates these
/// fields live AND persists them, so changes take effect without a restart.
class WebSearchService {
  WebSearchBackend backend;
  String serpApiKey;
  String searxngUrl;

  /// How many results to pull into context. Kept small to avoid blowing the
  /// context window and to keep the round-trip fast.
  final int maxResults;

  WebSearchService({
    WebSearchBackend? backend,
    String? serpApiKey,
    String? searxngUrl,
    this.maxResults = 5,
  })  : backend = backend ?? WebSearchBackend.off,
        serpApiKey = serpApiKey ?? '',
        searxngUrl = searxngUrl ?? '';

  /// Whether the selected backend has what it needs to run a search.
  bool get isConfigured {
    switch (backend) {
      case WebSearchBackend.serpapi:
        return serpApiKey.isNotEmpty;
      case WebSearchBackend.searxng:
        return searxngUrl.isNotEmpty;
      case WebSearchBackend.off:
        return false;
    }
  }

  /// Run a search and format the hits as an injectable context block, or null
  /// if search is off/unconfigured/returned nothing. Never throws — search is
  /// best-effort and must not break the send.
  Future<String?> buildContext(String query) async {
    final trimmed = query.trim();
    if (!isConfigured || trimmed.isEmpty) return null;

    List<WebSearchResult> results;
    try {
      results = await search(trimmed);
    } catch (_) {
      return null;
    }
    if (results.isEmpty) return null;

    final buffer = StringBuffer();
    buffer.writeln(
      'Web search results for "$trimmed". Use these to answer the question '
      'below, and cite the sources you rely on inline as [1], [2], etc. If the '
      'results do not contain the answer, say so.',
    );
    buffer.writeln();
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      buffer.writeln('[${i + 1}] ${r.title}');
      buffer.writeln(r.url);
      if (r.snippet.isNotEmpty) buffer.writeln(r.snippet);
      buffer.writeln();
    }
    buffer.write('[End of web search results]');
    return buffer.toString();
  }

  Future<List<WebSearchResult>> search(String query) {
    switch (backend) {
      case WebSearchBackend.serpapi:
        return _searchSerpApi(query);
      case WebSearchBackend.searxng:
        return _searchSearxng(query);
      case WebSearchBackend.off:
        return Future.value(const []);
    }
  }

  Future<List<WebSearchResult>> _searchSerpApi(String query) async {
    final uri = Uri.https('serpapi.com', '/search', {
      'engine': 'google',
      'q': query,
      'api_key': serpApiKey,
      'num': '$maxResults',
    });

    final response =
        await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return const [];

    final body = json.decode(response.body) as Map<String, dynamic>;
    final results = <WebSearchResult>[];

    // Lead with the answer box / knowledge graph when present — they're the
    // highest-signal hit SerpAPI returns.
    final answerBox = body['answer_box'] as Map<String, dynamic>?;
    if (answerBox != null) {
      final snippet = (answerBox['answer'] ??
              answerBox['snippet'] ??
              answerBox['result'] ??
              '')
          .toString();
      if (snippet.isNotEmpty) {
        results.add(WebSearchResult(
          title: (answerBox['title'] ?? 'Answer').toString(),
          url: (answerBox['link'] ?? '').toString(),
          snippet: snippet,
        ));
      }
    }

    final organic = body['organic_results'] as List<dynamic>? ?? const [];
    for (final item in organic) {
      if (item is! Map<String, dynamic>) continue;
      results.add(WebSearchResult(
        title: (item['title'] ?? '').toString(),
        url: (item['link'] ?? '').toString(),
        snippet: (item['snippet'] ?? '').toString(),
      ));
      if (results.length >= maxResults) break;
    }

    return results;
  }

  Future<List<WebSearchResult>> _searchSearxng(String query) async {
    // Tolerate a base URL with or without a trailing slash / scheme.
    var base = searxngUrl.trim();
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'http://$base';
    }
    base = base.replaceAll(RegExp(r'/+$'), '');

    final uri = Uri.parse('$base/search').replace(queryParameters: {
      'q': query,
      'format': 'json',
    });

    final response =
        await http.get(uri).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return const [];

    final body = json.decode(response.body) as Map<String, dynamic>;
    final raw = body['results'] as List<dynamic>? ?? const [];
    final results = <WebSearchResult>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      results.add(WebSearchResult(
        title: (item['title'] ?? '').toString(),
        url: (item['url'] ?? '').toString(),
        snippet: (item['content'] ?? '').toString(),
      ));
      if (results.length >= maxResults) break;
    }

    return results;
  }
}
