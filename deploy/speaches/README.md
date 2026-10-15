# Speaches for Horizon voice mode

Self-hosts both halves of voice mode on your own hardware: transcription via
faster-whisper, speech via Kokoro. No API keys, no per-hour billing.

## Run it

```bash
docker compose up -d
```

The compose file uses a named volume for models, so it can live anywhere.

**It publishes host port 8001, not 8000**, so it can share a box with
something that already holds 8000. Change the mapping if you'd rather.

## Pull the models

Models download on first use, but doing it up front means the first voice turn
isn't waiting on a multi-gigabyte fetch. The `latest-cuda` image has no CLI in
it (`uvx`/`speaches-cli` aren't installed), so use the API:

```bash
# Speech to text — turbo is the accuracy/speed sweet spot on a 3090
curl -X POST http://<host>:8001/v1/models/deepdml/faster-whisper-large-v3-turbo-ct2

# Text to speech
curl -X POST http://<host>:8001/v1/models/speaches-ai/Kokoro-82M-v1.0-ONNX
```

Useful neighbours on the same API:

| Call | Does |
|---|---|
| `GET /v1/registry` | Every downloadable model (726 of them) |
| `GET /v1/models` | What's actually installed |
| `GET /api/ps` | What's loaded in VRAM right now |
| `DELETE /api/ps/{id}` | Evict a loaded model — same idea as Ollama's keep_alive 0 |

## Point Horizon at it

Settings → Voice. Speaches is the **Accuracy pass** (the Whisper server that
cleans up the live transcript before it's sent) and the self-hosted voice;
live transcription itself is WhisperLive, see the main README.

| Section | Field | Value |
|---|---|---|
| Speech to text → **Whisper** | Server address | `http://<host>:8001` |
| | Remote address (optional) | the same server through a tunnel or Tailscale, for away from home |
| | Model | `deepdml/faster-whisper-large-v3-turbo-ct2` |
| Text to speech → **Self-hosted** | Server address | `http://<host>:8001` ("Use my speech server" fills it in) |
| | Model | `speaches-ai/Kokoro-82M-v1.0-ONNX` |
| | Voice | `af_heart` (tap a suggestion chip for others) |

Leave both API key fields empty — Speaches doesn't require one by default.

## Living alongside Ollama

Whisper large-v3-turbo at int8 is roughly 2 GB of VRAM and Kokoro-82M is
negligible, so on a 48 GB pair of 3090s this is noise next to a 27B model.
`WHISPER__TTL=300` releases it after five idle minutes, so between voice turns
the rig is back to exactly what it was.

If VRAM ever does get tight, `WHISPER__DEVICE=cpu` moves transcription to the
CPU entirely — slower, but it leaves the GPUs untouched. Kokoro is small
enough that CPU is a reasonable default for it regardless.

## Checking it works

```bash
curl http://<host>:8001/v1/models | head
```

There's also a browser UI at `http://<host>:8001` (`ENABLE_UI=true`)
for trying a model without going through the app.
