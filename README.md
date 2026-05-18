# Horizon

A multi-provider, multi-platform, open-source chat client built on Flutter. Talk to **Ollama** (your local models), **Claude** (Anthropic Messages API), and **OpenAI** (Chat Completions and reasoning models) from a single app — with per-conversation configs, secure on-device key storage, and an OLED-optimized dark theme.

Configure system prompts, switch models or providers mid-conversation, and fine-tune parameters — **all per-conversation, no global settings needed**. Native feel across iOS, Android, macOS, Windows, and Linux.

Get the latest [release here](https://github.com/60MilesPerHour/Horizon/releases).

## Features
- **Three providers, one app**: Ollama, Claude (Anthropic), OpenAI — pick any model per chat, mix providers freely in the same session history
- **Secure API key storage**: Cloud-provider keys live in the OS keystore via `flutter_secure_storage`, never in plaintext settings
- **Per-Conversation Configuration**: System prompt, model selection, and inference parameters (temperature, seed, context, tokens) — all configurable per chat
- **Live Model + Provider Switching**: Change models or providers mid-conversation without starting over
- **Smooth Streaming**: Typewriter-buffered output so bursty SSE feels fluid even on slow networks
- **Image Support**: Send images inline (Ollama vision models, Claude, GPT-4o etc.)
- **Message Editing & Regeneration**: Edit your messages and regenerate responses
- **Custom Models** (Ollama): Save your favorite prompt + config combos as new models
- **Responsive Design**: Optimized for mobile, tablet, and desktop — single codebase, native feel everywhere
- **Dark Theme**: OLED-optimized true black for power and battery savings
- **Bulletproof Networking**: Tagged provider errors, timeout handling, robust stream cleanup

## About
Horizon is a fork of the original [Reins](https://github.com/ibrahimcetin/reins) Flutter Ollama client by Ibrahim Çetin, extended into a fully multi-provider client with hardened networking and polish. Major changes from upstream:
- Multi-provider chat backend (Ollama + Claude + OpenAI) via a unified `ChatService` abstraction
- Self-healing per-chat provider routing (DB column + name-shape fallback)
- Typewriter smoothing for bursty cloud-provider SSE streams
- OLED-optimized dark theme
- Tagged provider errors for instant root-cause diagnosis
- Per-platform CI builds via GitHub Actions

## Contributing
Found a bug or have an idea? Issues and PRs welcome!

## License
Licensed under GPL-3.0 (same as the original Reins project).
