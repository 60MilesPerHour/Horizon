<div align="center">

<img src="assets/images/horizon.png" width="120" alt="Horizon logo">

# Horizon

**A multi-provider AI chat client built on Flutter.**
Talk to **Ollama**, **Claude**, **OpenAI**, and **Gemini** from a single app — with per-conversation configs, secure on-device key storage, and an OLED-optimized dark theme.

[**Download latest release ▸**](https://github.com/60MilesPerHour/Horizon/releases)

</div>

---

## Highlights

- **Four providers, one app.** Ollama (local), Claude (Anthropic), OpenAI (incl. o-series reasoning), Gemini (Google). Mix providers freely across chats — or even mid-chat.
- **Per-conversation everything.** Model, provider, system prompt, temperature, context size, max tokens — all stored per chat. No global toggles to babysit.
- **Live model + provider switching.** Switch from a local Llama to Claude Sonnet mid-thread without losing history.
- **Self-hosted-friendly Ollama setup.** Configure a *primary* and a *backup* server URL. Requests fail over automatically when the primary is unreachable — keep your home-LAN address private and let traffic transparently route through your VPN/Tailscale endpoint when you're off-network.
- **Secure key storage.** Cloud-provider API keys live in the OS keystore via `flutter_secure_storage` — never in plaintext settings or app data.
- **Smooth streaming.** Typewriter buffer plus plain-text rendering during the stream means responses don't turn into a slideshow as they grow. Markdown renders cleanly once the response completes (selectable, code blocks, GFM tables, the works).
- **OLED true-black dark theme.** Free AMOLED battery, pleasant at night.
- **Image input** on every vision-capable model — Ollama vision, Claude, GPT-4o, Gemini.
- **Edit & regenerate.** Edit any of your past messages and regenerate the assistant's response from there.
- **Custom Ollama models.** Save your favourite prompt + config combo as a fresh Ollama model — Horizon calls `/api/create` for you.
- **Responsive layout.** Same Flutter codebase tuned for phone, tablet, and desktop.

## Install

| Platform | Download | Notes |
|---|---|---|
| **Android** | `horizon-vX.Y.Z.apk` from [Releases](https://github.com/60MilesPerHour/Horizon/releases) | Signed. Sideload via files/adb. |
| **macOS** | `horizon-macos.zip` from [Releases](https://github.com/60MilesPerHour/Horizon/releases) | Unsigned. After unzip: `xattr -dr com.apple.quarantine /Applications/horizon.app` |
| **Windows** | `horizon-windows.zip` from [Releases](https://github.com/60MilesPerHour/Horizon/releases) | Extract and run `horizon.exe`. VC++ runtime DLLs are bundled. |
| **iOS** | Not currently distributed | Buildable from source if you have an Apple Developer account. |
| **Linux** | Build from source | `flutter run -d linux` |

## Configure

1. **Ollama** — Settings → Server → enter `http://<host>:11434`. Optionally enter a backup URL (Tailscale, VPN, etc.) — used automatically when the primary can't be reached.
2. **Cloud providers** — Settings → Cloud Providers → paste API keys for Anthropic, OpenAI, and/or Google. Models from every configured provider show up in the model picker, grouped by provider.

That's it.

## Compared to upstream Reins

Horizon is a fork of [Reins](https://github.com/ibrahimcetin/reins) — a clean Flutter Ollama client by [Ibrahim Çetin](https://github.com/ibrahimcetin). Upstream's last public release was 1.2.0 and the repo has been quiet since; this fork started as a personal stability patch and grew into a multi-provider client. Major changes:

| Area | Reins (1.2.0) | Horizon (3.2.1) |
|---|---|---|
| Backends | Ollama only | Ollama + Claude + OpenAI + Gemini |
| Server reachability | Single URL | Primary + backup URL with automatic failover |
| Network reliability | A few hang/leak edges | 30 s timeouts everywhere, stream-subscription cleanup, JSON parse guards, tagged provider errors |
| Streaming feel | Per-token rebuilds (jittery on bursty SSE) | Typewriter buffer + plain-text live render → Markdown on completion |
| `num_ctx` behaviour | Always sent, always 2048 default → forced Ollama to reload models | Defaults to "let the server decide"; opt-in override per chat |
| Multi-provider routing | n/a | `ChatService` abstraction, per-chat `provider` column, self-healing on read |
| Key storage | n/a | OS keystore via `flutter_secure_storage` |
| Theme | Material default | OLED true-black dark + dynamic colour |
| Platform builds | Manual | GitHub Actions: Android (signed), macOS, Windows on every push |
| Distribution | APK only (1.2.0) | Android APK + macOS app + Windows exe per release |

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
