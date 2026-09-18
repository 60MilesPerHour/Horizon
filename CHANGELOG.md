# Changelog

Released versions only. Every entry here corresponds to a tag and a GitHub
release with all five build artifacts; anything not listed never shipped.

## Versioning

From v4.0.0 onwards:

- **MAJOR** — breaking changes: a platform minimum rises, or a database
  migration can't be rolled back.
- **MINOR** — new features.
- **PATCH** — fixes and refinements.
- **The version in `pubspec.yaml` only changes when a release is cut.**
  Commits between releases leave it alone.

That last rule is the one that was missing. Earlier in the v3 line the
version was bumped per commit while releases were cut in batches, which
produced four version numbers that exist in `pubspec.yaml` history but were
never released:

| Never released | Shipped as part of |
|---|---|
| 3.9.1, 3.10.0 | **v3.11.0** |
| 3.11.1, 3.12.0 | **v3.13.0** |

Nothing published is wrong — all 33 release tags match their `pubspec.yaml`
exactly — and the history has deliberately not been rewritten to tidy this,
because renumbering would repoint every one of those tags at an orphaned
commit for a purely cosmetic gain. Gaps in the released sequence (there is no
3.10.x or 3.12.x) are just gaps.

---

## v3.13.1 — 2026-09-18

Audition TTS voices before choosing one. A play button on every voice picker
reads a sample line aloud; Kokoro offers 54 voices and their names say nothing
about how they sound. The self-hosted voice list is now read from the server
rather than a hardcoded set of suggestions.

## v3.13.0 — 2026-09-18

Chat branching, and a settings page that stops sprawling.

- **"Branch from here"** on any message forks the chat, keeping history up to
  that point. Unlike editing or regenerating, the original survives.
- Settings reorganised into categories: Ollama Server, Cloud Models, Tools &
  Web Search, Voice, Appearance, Backup & Restore, About.
- Speech-server **model and voice fields are pickers** populated from the
  server, instead of typed model ids.
- **Network scan** for speech servers, alongside the existing Ollama scan.
- Build toolchain moved to Flutter 3.44, matching the development environment.
- Schema v4 (chat lineage). Plain column additions, no table rebuild.

## v3.11.0 — 2026-09-18

Self-hostable voice, end to end.

- **Three speech-to-text backends**: the device recogniser (default, free,
  offline), any OpenAI-compatible Whisper server, or ElevenLabs Scribe.
- **Three text-to-speech engines**: device, self-hosted `/v1/audio/speech`
  (Speaches with Kokoro), or ElevenLabs. So one Speaches container covers both
  directions with no API keys.
- Endpointing measures the room and ends a turn after 900 ms of silence,
  against the platform recogniser's fixed 3 seconds.
- Voice mode gained a model picker in its app bar and optional typed input.
- Voice settings moved to their own page.
- An unreachable backend falls back to the device for that turn, and says so.

## v3.9.0 — 2026-09-18

Voice mode, and the Android digital-assistant role.

- Hands-free voice mode over a persistent assistant chat, so tools,
  attachments and history all work as in a normal chat.
- Replies are spoken sentence by sentence as they stream.
- Horizon can be selected as Android's digital assistant, so the assist
  gesture opens it.
- **minSdk 24** (Android 7.0+) and **macOS 11+**, both required by the speech
  plugins.

## v3.8.0 — 2026-09-18

Native tool calling, attachments, code blocks, OpenRouter.

- **Real function calling** in all four provider dialects, replacing the
  prompt-convention search pass. Tools: web search, page fetch, clock.
- **Document attachments**: PDF, CSV, JSON/YAML, source files, plain text.
- Fenced code blocks get syntax highlighting and a copy button.
- **OpenRouter** as the recommended cloud path — one key, hundreds of models,
  with per-model capability metadata.
- Schema v3: `tool` becomes a legal message role, which required rebuilding
  the messages table.

## v3.7.5 — 2026-07-25

Cloudflare Access blocks now report what actually happened instead of a JSON
parse error, and the connection probe no longer reads an Access login page as
a healthy server.

## v3.7.4 — 2026-07-25

Stable release signing, so Android updates install in place instead of
requiring an uninstall.

## v3.7.3 — 2026-07-25

Cloudflare Access service-token support, making a tunnel hostname a usable
remote path for the Ollama server.

## v3.7.2 — 2026-07-19

Per-provider kill switches, off by default, so a fresh install is Ollama-only
and the model list can't fixate on a cloud provider.

## v3.7.1 — 2026-06-12

Generation survives backgrounding on Android via a foreground service held
only while streaming; smoother rendering for models that emit in bursts; and
partial replies are saved when a stream dies instead of vanishing.

## v3.7.0 — 2026-06-11

Network reliability overhaul and in-app Ollama model management.

- Shared HTTP client with a 6 s connect timeout, stall guards, and retry on
  connection-level failures.
- Real error messages everywhere, instead of "something went wrong".
- Load, unload, pull and delete models on the server from the app.

## v3.6.2 — 2026-06-09

Web search reliability: the SerpAPI key persists when pasted, the toggle is
gated on a configured backend, and the decision pass got much cheaper.

## v3.6.1 — 2026-06-06

Web search reworked to decide-then-search, so it no longer searches every
message, with citations and a visible searching state.

## v3.6.0 — 2026-06-06

Artifacts: substantial documents and code files render as a card with a
dedicated viewer.

## v3.5.0 — 2026-06-06

Per-chat web search, with SerpAPI or a self-hosted SearXNG.

## v3.4.8 — 2026-05-30

Fixed a fresh Linux install crashing at startup: the bundled SQLite lookup
now falls back to the versioned library name.

## v3.4.7 — 2026-05-30

Linux packaging fixes.

## v3.4.3 — 2026-05-25

Fixed the Linux taskbar icon by matching `StartupWMClass` to the application
id rather than the binary name.

## v3.4.0 – v3.4.2 — 2026-05-20

Per-chat export to Markdown and text, with import to restore.

## v3.3.0 — 2026-05-19

Ollama Cloud authentication and a per-chat thinking toggle.

## v3.2.0 – v3.2.8 — 2026-05-19

Scroll and rendering work, the Gemini provider, a backup server address, and
the first Linux build.

## v3.1.4 – v3.1.5 — 2026-05-18

Multi-provider groundwork: Claude and OpenAI alongside Ollama, plus macOS and
Windows builds.

## v3.0.2 — 2026-05-15

First release under the Horizon name: rebranded from Reins, OLED dark theme,
and nine networking fixes.
