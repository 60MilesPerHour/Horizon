/// Constants for the artifacts feature.
///
/// Horizon talks to raw provider APIs, so there's no native artifact protocol
/// — we establish one with a system-prompt convention and parse it client-side
/// (the same approach as the `<think>` block and the web-search injection).
class ArtifactConstants {
  /// The tag the model is asked to wrap standalone deliverables in. Kept in
  /// sync with the parser (`ArtifactBlockSyntax`).
  static const String tag = 'artifact';

  /// Appended to a chat's system prompt when artifacts are enabled. Tells the
  /// model WHAT to wrap (substantial, reusable, standalone things) and — just
  /// as important — what NOT to wrap (short snippets, inline examples), so the
  /// chat doesn't turn every code block into a card.
  static const String systemPromptAddon = '''

# Artifacts

When you produce a substantial, self-contained deliverable that the user will likely keep, reuse, or edit — a complete document, a full code file or program, a long structured piece of writing — wrap it in an artifact tag:

<artifact title="Short descriptive title" type="markdown|code" lang="dart">
...the full content...
</artifact>

Rules:
- Use type="code" with an appropriate `lang` for source files; use type="markdown" for prose, documents, and notes.
- Put ONLY the deliverable inside the tag. Keep your explanation, reasoning, and conversational reply outside it.
- Do NOT wrap short snippets, quick examples, single commands, or anything under ~15 lines — those stay as normal inline fenced code blocks.
- Emit at most one artifact per reply unless the user explicitly asks for several.
- The artifact content must be complete and ready to use on its own, with no "...rest of the code" placeholders.''';
}
