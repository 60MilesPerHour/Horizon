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

## v4.0.0 — 2026-09-18

One cloud backend instead of four, a settings section that can answer "where
does my data go", and the assistant can now reach both your other
conversations and your house.

**Breaking — the direct Anthropic, OpenAI and Google clients are gone.**
Horizon spoke those three APIs natively: three keys, three request dialects,
three tool protocols, and per-model capabilities that had to be guessed from
model names. OpenRouter serves the same models behind one key and one protocol
and reports what each model actually supports. So the three clients were
deleted, and a database migration (schema v5) repointed every chat that used
one at OpenRouter, rewriting its model id to the equivalent slug
(`claude-sonnet-4-5-20250929` becomes `anthropic/claude-sonnet-4.5`). A slug is
a best-effort mapping, so the original provider and model id are kept on the
row rather than discarded: if a chat lands on a model that doesn't exist, what
it used to run on is still recorded. The same mapping runs when a chat is
imported, since an export file written by v3 never passes through a migration.

Two things this does *not* do: your `anthropic_api_key`, `openai_api_key` and
`google_api_key` stay in the OS keystore untouched — nothing reads them, but
silently deleting a credential isn't the app's call — and the "OpenAI Base URL"
field that let Horizon talk to an arbitrary OpenAI-compatible endpoint went
with the OpenAI client.

- **Security & Privacy.** A new settings page listing every destination data
  can leave for, grouped into on-device, your own hardware, and third parties.
  Each row says what exactly goes there, whether it's happening right now, and
  where the credential lives. It's read from your live configuration rather
  than written by hand, and it's deliberately blunt where "private" is weaker
  than it sounds: that OpenRouter forwards your conversation to whoever serves
  the model, that Android's speech recogniser ships your audio to Google unless
  an offline language pack is installed, that `ollama.com` is not your own
  hardware, that an Ollama address outside your LAN means traffic leaving your
  network, and that the config backup is plaintext by design. It reads whether
  a key exists, never its value, so a screenshot of the page can't leak one.

- **Home Assistant.** Point Horizon at your instance with a long-lived token
  and the model can list entities, read one's state, and call services — check
  a sensor, turn something on, set a temperature, run a scene. It looks entity
  ids up rather than guessing them, and reports what actually changed instead
  of assuming a 200 meant something happened. "Test connection" tells you
  which of the URL and the token is wrong, in Settings, rather than mid-
  sentence in a voice conversation. The token is unscoped because Home
  Assistant has no scopes for long-lived tokens; the page says so.

- **Conversations can be shared with the assistant.** Turn on "Share with
  assistant" in a chat's Configure Chat sheet and any other chat — voice mode
  included — can search it with a new `search_chats` tool when it needs
  something you worked out there. Off by default and per chat: the useful
  version of this is the one where the assistant can reach the conversation
  that matters and cannot reach the ones that don't. Nothing is injected into
  a prompt behind your back — the model has to ask, the search runs locally,
  and it only ever gets matching excerpts with the conversation name and date.
  The tool isn't even offered to a model until at least one chat is shared.

- **Appearance, properly.** Light / dark / system as a labelled control
  instead of an unlabelled button that cycled through three states with no way
  to tell which one it was in. Twelve accent presets plus a custom colour
  picker, five palette styles from neutral to vibrant, true-black or dim dark
  mode, translucent frosted chrome, corner radius, text size and compact
  density — with a live preview, because "vibrant on true black at radius 4"
  is not something anyone can picture from a label. Existing themes carry
  over: the old colour and brightness settings are still read.

- **Voice mode stops re-sending its whole history.** Voice deliberately reuses
  one long-lived chat so it remembers the last thing it was asked, and nobody
  ever prunes it — so it grew without limit, and eventually every "what's the
  time" re-sent months of conversation. What's *sent* is now capped at two
  dozen messages; the stored transcript stays complete and readable. The cut
  always lands on one of your turns, never on a tool result whose call has
  been trimmed away, which every OpenAI-compatible endpoint rejects outright.
  The chat also gets its own icon in the sidebar, since it isn't a
  conversation you started.

- **About points at Horizon.** Every link on that page still pointed at
  upstream Reins — its repository, its website, and its App Store id behind
  the review button, so "Give a Star" starred someone else's project. They now
  point here, with upstream credited explicitly instead of accidentally:
  Horizon is a GPL-3.0 fork of [Reins](https://github.com/ibrahimcetin/reins)
  by Ibrahim Çetin, and the page says so. The version number is read from the
  bundle, so the number in a bug report is the real one.

---

## v3.14.0 — 2026-09-18

Voice mode became a conversation, and three bugs that made it feel broken are
fixed.

- **Continuous mode.** After a reply finishes it listens again on its own, so
  a conversation doesn't need a tap per turn. Tapping while it listens means
  "I'm done"; an End button stops the session; two silent turns end it
  automatically. The microphone is only ever open during a listening phase.
- **End-of-turn detection went from 30+ seconds to about a second.** Android
  frequently ignores the `pauseFor` hint, so a turn ran to the hard listen
  limit — half a minute of dead air after you stopped talking. Endpointing no
  longer relies on the platform: it watches the transcript and ends the turn
  once it stops changing.
- **The control stays still.** Everything below the transcript had variable
  height, so the mic drifted under your thumb between turns. It's now an orb
  in a fixed footprint whose halo reacts to your voice.
- **No more glitched characters mid-reply.** Streaming text was being sliced
  at UTF-16 boundaries, so any cut through an emoji briefly emitted half a
  character.
- **Faster activation** — the recogniser is prepared when the screen opens
  rather than on first tap.

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
