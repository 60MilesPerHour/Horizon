# openWakeWord training, locally

The [openWakeWord training Colab](https://colab.research.google.com/drive/1-4LGnYvOduDPTvQ98Ydv4yjw5zlfI8Oz)
is the one everyone recommends, and the training code it drives is fine. The
notebook around it is the fragile part.

## Why the Colab run failed

Two separate things, both fixed here.

**1. The phrase.** `Hey Ass-trul` contains a hyphen. openWakeWord's own
guidance in that notebook says to spell sounds out phonetically with
*underscores* between parts (`hey siri` → `hey_seer_e`), spell numbers as
words, and avoid punctuation. A hyphen reads as a phonetic separator to a
human but it's punctuation to the phonemizer.

It's worse than cosmetic: the notebook does
`model_name = target_phrase.replace(" ", "_")`, so the phrase becomes both the
output *filename* and the label openWakeWord registers the model under — the
string your app has to match on. `hey_ass_trul` is the spelling you want.

`train.py` now refuses a hyphenated phrase up front and tells you what to use,
rather than failing an hour in or silently producing `Hey_Ass-trul.tflite`.

**2. The environment.** The notebook installs its own torch at runtime:

```
pip install torch==2.5.0 torchvision==0.20.0 torchaudio==2.5.0 --index-url .../whl/cu121
```

That's a resolution fight it loses the moment the host Python or CUDA moves —
and Colab has moved to Python 3.12, while the notebook's own comment says the
ONNX → tflite step "works for python 3.11". Same story for `datasets==2.14.6`,
`speechbrain==0.5.14` and friends, all pinned to 2023 and increasingly unhappy
next to a modern `huggingface_hub`.

The fix isn't newer pins, it's not installing torch at runtime at all. The
image is `pytorch/pytorch:2.5.1-cuda12.1-cudnn9-devel`, which already has the
right torch, CUDA and Python 3.11, and nothing here passes `--index-url`.

## Use it

```bash
docker compose build          # ~10 min, mostly the torch base image

# Listen before you commit to a training run. Do this every time you change
# the phrase — an hour of training will faithfully learn a mispronunciation.
docker compose run --rm preview hey_ass_trul
#   -> ./out/preview.wav

docker compose run --rm train hey_ass_trul
#   -> ./out/hey_ass_trul.onnx
#   -> ./out/hey_ass_trul.tflite
```

## Defaults worth knowing

| Flag | Default here | Notebook | Why |
|---|---|---|---|
| `--samples` | 30000 | 1000 | The notebook's own text says 30k–50k "is often the best" and only defaults low because Colab is slow. On a local 3090 there's no reason to take the small one. |
| `--steps` | 50000 | 10000 | Same reasoning. |
| `--false-activation-penalty` | 1500 | 1500 | Raise it if it wakes on its own; lower it if it ignores you. |

Datasets cache in `./data` (~3 GB: AudioSet slice, an hour of music, room
impulse responses, and ~2 GB of pre-computed negative features), so a second
run with a different phrase skips all the downloading.

## Output

Both `.onnx` and `.tflite` — openWakeWord's exporter produces the ONNX and
`onnx2tf` converts it. Horizon will want the `.tflite`, plus openWakeWord's
two shared feature models (`melspectrogram.tflite` and
`embedding_model.tflite`), which are **not** part of your trained model. The
Colab fetches those at runtime via `openwakeword.utils.download_models()`;
they're baked into this image, and they'll need bundling as app assets since
there's no Python in the app to fetch them.
