# Speaches for Horizon voice mode

Self-hosts both halves of voice mode on your own hardware: transcription via
faster-whisper, speech via Kokoro. No API keys, no per-hour billing.

## Run it

```bash
docker compose up -d
```

## Pull the models

Models download on first use, but doing it up front means the first voice turn
isn't waiting on a multi-gigabyte fetch:

```bash
# Speech to text — turbo is the accuracy/speed sweet spot on a 3090
docker exec speaches uvx speaches-cli model download deepdml/faster-whisper-large-v3-turbo-ct2

# Text to speech
docker exec speaches uvx speaches-cli model download speaches-ai/Kokoro-82M-v1.0-ONNX
```

## Point Horizon at it

Settings → Voice:

| Field | Value |
|---|---|
| Speech to text | **Whisper** |
| Server address | `http://172.16.23.20:8000` |
| Model | `deepdml/faster-whisper-large-v3-turbo-ct2` |
| Text to speech | **Self-hosted** |
| Server address | `http://172.16.23.20:8000` (prefilled from the above) |
| Model | `speaches-ai/Kokoro-82M-v1.0-ONNX` |
| Voice | `af_heart` (tap a suggestion chip for others) |

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
curl http://172.16.23.20:8000/v1/models | head
```

There's also a browser UI at `http://172.16.23.20:8000` (`ENABLE_UI=true`)
for trying a model without going through the app.
