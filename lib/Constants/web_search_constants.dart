/// Prompts for the web-search feature.
///
/// Horizon talks to raw provider APIs, so there's no native search tool. We
/// run a lightweight client-side agentic loop: a cheap decision pass asks the
/// model whether the latest message needs fresh info, and only then do we
/// actually search — so it doesn't search literally everything.
class WebSearchConstants {
  /// System prompt for the decision pass. The model must answer with ONLY a
  /// `<search>…</search>` directive or `<nosearch>`. Deliberately conservative:
  /// when in doubt it should NOT search.
  static const String decisionSystemPrompt = '''
You decide whether answering the user's latest message requires a web search for current, real-time, or external information — recent events, news, prices, schedules, releases, sports, weather, or niche/fast-changing facts you can't be confident are current.

If a web search would materially help, reply with ONLY:
<search>a concise search query</search>

Otherwise — small talk, general knowledge you already know, reasoning, coding, or anything not dependent on fresh external info — reply with ONLY:
<nosearch>

Output nothing else. No explanation, no extra text.''';

  /// Appended to the chat's own system prompt for the ANSWER pass whenever web
  /// search is enabled, regardless of what the user's system prompt says. Tells
  /// the model it has search and how to cite.
  static const String systemPromptAddon = '''

# Web Search

You have a web search tool. When a search is performed, numbered results are included in the user's message. Use them to answer, and:
- Cite every claim drawn from a result inline with its number in brackets, e.g. [1] or [2], matching the numbered results.
- End your answer with a "Sources" section listing each cited number with its page title and URL.
- Only cite results you actually used; if the results don't answer the question, say so.
When no results are provided, answer normally from your own knowledge.''';
}
