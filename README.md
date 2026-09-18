<div align="center">

<img src="assets/images/horizon.png" width="120" alt="Horizon logo">

# Horizon

**A multi-provider AI chat client built on Flutter.**
Talk to a local **Ollama** server and to every hosted model on **OpenRouter** — Claude, GPT, Gemini, Llama, Qwen and several hundred more — from a single app, with per-conversation configs, secure on-device key storage, and an OLED-optimized dark theme.

[**Download latest release ▸**](https://github.com/60MilesPerHour/Horizon/releases)

</div>

---

## Highlights

- **Local and hosted, one app.** Ollama (local + Ollama Cloud) for anything on your own hardware; OpenRouter for everything else, on one key and one bill. Mix them freely across chats — or even mid-chat. Horizon spoke to Anthropic, OpenAI and Google directly until v4.0.0; OpenRouter serves the same models behind one protocol and, unlike those endpoints, reports per-model capabilities, so the picker can show what each model actually supports instead of guessing from its name.
- **Per-conversation everything.** Model, provider, system prompt, temperature, context size, max tokens — all stored per chat. No global toggles to babysit.
- **Live model + provider switching.** Switch from a local Llama to Claude Sonnet mid-thread without losing history.
- **Chat branching.** Fork a conversation at any message and explore a different path without losing the original.
- **Home Assistant control.** Point Horizon at your HA instance and the model can read sensors and call services — "is the garage shut", "set the office to 20", "run the movie scene". Entity ids are looked up, never guessed.
- **Cross-chat memory, per chat.** Share a conversation with the assistant and any other chat — including voice mode — can search it when it needs something you worked out there. Off by default, opt in per chat, and the model has to ask: nothing is injected into a prompt behind your back.
- **A security page that reads your config, not a promise.** Settings → Security & Privacy lists every destination data can leave for, what exactly goes there, whether it's happening right now, and where each credential lives — grouped into on-device, your own hardware, and third parties. It's blunt about the awkward parts: that OpenRouter forwards your conversation to whoever serves the model, that Android's speech recogniser may ship your audio to Google, and that the config backup is plaintext by design.
- **Appearance, properly.** Light/dark/system, any accent colour, five palette styles, true-black or dim dark mode, frosted translucent chrome, corner radius, text size and density — with a live preview.
- **Self-hosted-friendly Ollama setup.** Configure a *primary* and a *backup* server URL. Requests fail over automatically when the primary is unreachable — keep your home-LAN address private and let traffic transparently route through your VPN/Tailscale endpoint when you're off-network.
- **Ollama Cloud + bearer auth.** Optional Authorization token for Ollama Cloud (ollama.com) or any reverse-proxy that gates a self-hosted Ollama behind auth.
- **Per-chat thinking toggle.** Three-state `think` control (Default / On / Off) for Ollama models with a thinking phase (Qwen 3, gpt-oss, etc.). Models without one ignore it.
- **Secure key storage.** Cloud-provider API keys live in the OS keystore via `flutter_secure_storage` — never in plaintext settings or app data.
- **Smooth streaming.** Typewriter buffer plus plain-text rendering during the stream means responses don't turn into a slideshow as they grow. Markdown renders cleanly once the response completes (code blocks, GFM tables, the works).
- **OLED true-black dark theme.** Free AMOLED battery, pleasant at night — or Dim, if you're on an LCD.
- **Image input** on every vision-capable model, with support read from OpenRouter per model rather than inferred.
- **Edit & regenerate.** Edit any of your past messages and regenerate the assistant's response from there.
- **Custom Ollama models.** Save your favourite prompt + config combo as a fresh Ollama model — Horizon calls `/api/create` for you.
- **Responsive layout.** Same Flutter codebase tuned for phone, tablet, and desktop.

## Install

| Platform | Download | Notes |
|---|---|---|
| **Android** | `horizon-vX.Y.Z.apk` from [Releases](https://github.com/60MilesPerHour/Horizon/releases) | Signed. Sideload via Files/adb. |
| **macOS** | `horizon-macos.zip` from [Releases](https://github.com/60MilesPerHour/Horizon/releases) | Unsigned. After unzip: `xattr -dr com.apple.quarantine /Applications/horizon.app` |
| **Windows** | `horizon-windows.zip` from [Releases](https://github.com/60MilesPerHour/Horizon/releases) | Extract and run `horizon.exe`. VC++ runtime DLLs are bundled. |
| **Debian / Ubuntu / Mint / Pop** | `horizon_X.Y.Z_amd64.deb` from [Releases](https://github.com/60MilesPerHour/Horizon/releases) | `sudo apt install ./horizon_X.Y.Z_amd64.deb` |
| **Other Linux** | `horizon-X.Y.Z-linux-x64.tar.gz` from [Releases](https://github.com/60MilesPerHour/Horizon/releases) | Extract and run `./horizon` |
| **iOS** | Not currently distributed | Buildable from source if you have an Apple Developer account. |

## Configure

1. **Ollama** — Settings → Server → enter `http://<host>:11434`. Optionally enter a backup URL (Tailscale, VPN, etc.) — used automatically when the primary can't be reached. For **Ollama Cloud**, set the primary to `https://ollama.com` and paste your `olc-...` token in the API Token field below.
2. **Cloud models** — Settings → Cloud Models → paste your OpenRouter key (`sk-or-v1-...`). It enables itself as soon as a key is present, and every model OpenRouter serves shows up in the picker with its price per million tokens.
3. **Home Assistant** (optional) — Settings → Home Assistant → instance URL plus a long-lived access token from your HA profile → Security. "Test connection" tells you which of the two is wrong. The token is unscoped, because HA has no finer-grained scope for long-lived tokens: the model can do anything it can.
4. **Per-chat thinking** (Ollama) — Configure Chat → Thinking → Default / On / Off. Leave at Default unless you need to force a thinking-capable model on or off.

That's it.

## Compared to upstream Reins

Horizon is a fork of [Reins](https://github.com/ibrahimcetin/reins) — a clean Flutter Ollama client by [Ibrahim Çetin](https://github.com/ibrahimcetin). Upstream's last public release was 1.2.0 and the repo has been quiet since; this fork started as a personal stability patch and grew into a multi-provider client. Major changes:

| Area | Reins (1.2.0) | Horizon (3.3.0) |
|---|---|---|
| Backends | Ollama only | Ollama (local + Cloud) + OpenRouter (Claude, GPT, Gemini, Llama, Qwen, …) |
| Server reachability | Single URL | Primary + backup URL with automatic failover |
| Authenticated Ollama | n/a | Optional bearer token for Ollama Cloud / proxied servers |
| Per-chat `think` toggle | n/a | Three-state Default/On/Off |
| Network reliability | A few hang/leak edges | 30 s timeouts everywhere, stream-subscription cleanup, JSON parse guards, tagged provider errors |
| Streaming feel | Per-token rebuilds (jittery on bursty SSE) | Typewriter buffer + plain-text live render → Markdown on completion |
| `num_ctx` behaviour | Always sent, always 2048 default → forced Ollama to reload models | Defaults to "let the server decide"; opt-in override per chat |
| Multi-provider routing | n/a | `ChatService` abstraction, per-chat `provider` column, self-healing on read |
| Key storage | n/a | OS keystore via `flutter_secure_storage` |
| Theme | Material default | OLED true-black dark + dynamic colour |
| Platform builds | Manual | GitHub Actions: Android (signed APK), macOS, Windows, Linux (.deb + tar.gz) on every push |
| Distribution | APK only (1.2.0) | Android APK + macOS app + Windows exe + Linux .deb / tar.gz per release |

Anything that was good in Reins — the responsive layout, the chat-configure sheet, the model-selection bottom sheet, the inline Markdown rendering — is still good in Horizon. The diff is purely additive.

## Build from source

Local Flutter dev works for Android/macOS/Linux. iOS and Windows generally route through CI.

```bash
git clone https://github.com/60MilesPerHour/Horizon.git
cd Horizon
flutter pub get
flutter run                  # uses current device
flutter build apk --release  # Android
flutter build macos --release
flutter build windows --release
```

Dart SDK ≥ 3.5.4 required. Flutter 3.27.x recommended (this is what CI pins).

## Contributing

Issues and PRs welcome. Quick rules of the road:
- Keep changes per-platform-buildable. CI builds Android + macOS + Windows on every push to `main` and on PRs.
- Don't break per-chat isolation — anything that touches the request path should respect `chat.provider`.
- New providers go in `lib/Services/<name>_service.dart` and register through `ChatServiceRegistry`.

## Credit

Built on top of [Reins](https://github.com/ibrahimcetin/reins) by [Ibrahim Çetin](https://github.com/ibrahimcetin). Thank you for shipping a clean, hackable Flutter Ollama base — every multi-provider, networking, and polish change in Horizon stands on top of your work.

## License

[GPL-3.0](LICENSE), inherited from Reins. Modifications and additions © Miles Oldenburger 2026.
