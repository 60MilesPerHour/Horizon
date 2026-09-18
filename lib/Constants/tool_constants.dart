/// Guidance appended to the system prompt when tools are declared.
///
/// Tool *descriptions* tell a model what a tool does; they're poor at telling
/// it when to reach for one, and small local models in particular will answer
/// a "what happened this week" question from stale weights unless told
/// otherwise. This addon covers the behaviours the descriptions can't:
/// searching before guessing, reading a page instead of trusting a snippet,
/// and citing what was actually used.
class ToolConstants {
  static const String systemPromptAddon = '''

# Tools

You can call tools. Use them instead of guessing:
- Anything that depends on the present moment — "today", "now", ages, deadlines, whether something has happened yet — starts with current_time.
- Anything that may have changed since your training data, or that you are not confident about, starts with web_search. Never state a recent fact from memory when you could check it.
- Search snippets are truncated and often misleading. When a result looks like it holds the answer, call web_fetch on that URL and read the page before answering.
- If the user gives you a URL, fetch it rather than describing what it probably says.

When you have used a tool:
- Cite the sources you actually relied on inline as [1], [2], matching the results you used, and list them with titles and URLs at the end of your answer.
- Say plainly when the tools did not find the answer. Do not fill the gap with a guess presented as fact.

Do not call a tool for small talk, reasoning, writing, or knowledge that does not change. Do not announce that you are about to call a tool — just call it.''';
}
