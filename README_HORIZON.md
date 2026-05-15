# Horizon

A customization of [Reins](https://github.com/ibrahimcetin/reins) with enhanced networking reliability and bug fixes.

## What's Fixed

This version addresses critical reliability issues found in the original Reins app:

- **HTTP Timeouts** — All network requests now timeout after 30s instead of hanging indefinitely
- **Stream Resource Leaks** — Properly cancels streams to prevent memory accumulation
- **Race Conditions** — Fixed chat switching during message streaming
- **Null Safety** — Added proper error handling for malformed API responses
- **Image Handling** — Gracefully handles deleted or inaccessible image files
- **JSON Parsing** — Wrapped all JSON decoding in error handlers

## Building

### Via GitHub Actions (Recommended)
Push to the repo to automatically build release APKs. Downloads are available in the Actions artifacts.

### Local Build
```bash
flutter pub get
flutter build apk --release
```

## About Reins
Horizon is based on [Reins](https://github.com/ibrahimcetin/reins), a Flutter app for chatting with local Ollama models. This fork focuses on stability and reliability improvements.
