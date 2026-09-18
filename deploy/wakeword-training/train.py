#!/usr/bin/env python
"""Train a custom openWakeWord model, headless, on a local GPU.

This is the openWakeWord "automatic model training" Colab reduced to a script.
Differences that matter:

  * No pip installs at runtime. Everything is pinned in the image, so a run
    can't break because an upstream index moved.
  * No google.colab import, so it runs anywhere and can't die on a session
    timeout partway through.
  * The phrase is validated rather than passed through. The notebook quietly
    turns the phrase into the model name and the model's registered label, so
    punctuation in the phrase ends up in a filename and in the label your app
    has to match on.
  * Datasets are cached under /data, so a second run doesn't re-download
    ~2 GB of features and noise.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterator

import numpy as np
import scipy.io.wavfile
import yaml
from tqdm import tqdm

OWW = Path("/work/openwakeword")
DATA = Path("/data")
OUT = Path("/out")


def run(cmd: list[str] | str, **kw) -> None:
    """Run a command, streaming output, and stop on failure."""
    shell = isinstance(cmd, str)
    printable = cmd if shell else " ".join(cmd)
    print(f"\n$ {printable}", flush=True)
    subprocess.run(cmd, shell=shell, check=True, **kw)


def validate_phrase(phrase: str) -> str:
    """Reject phrases that will cause trouble later rather than at the end.

    openWakeWord's own guidance: spell sounds out phonetically with
    underscores between parts ("hey siri" -> "hey_seer_e"), spell numbers as
    words, and avoid punctuation. The notebook enforces none of this, and the
    phrase becomes both the output filename and the model's label.
    """
    cleaned = phrase.strip()
    if not cleaned:
        raise SystemExit("The phrase is empty.")

    # Hyphens are the trap: they read as a phonetic separator to a human, but
    # they're punctuation to the phonemizer and they land in the filename.
    if "-" in cleaned:
        suggestion = cleaned.replace("-", "_").replace(" ", "_").lower()
        raise SystemExit(
            f"'{cleaned}' contains a hyphen. openWakeWord wants underscores "
            f"between phonetic parts and no punctuation — the phrase also "
            f"becomes the model filename and label.\n\nTry: {suggestion}"
        )

    if re.search(r"[^A-Za-z_ ]", cleaned):
        raise SystemExit(
            f"'{cleaned}' has characters that don't belong in a wake phrase. "
            "Letters, spaces and underscores only; spell numbers as words."
        )

    return cleaned


def decode_to_16k_mono(raw: bytes) -> "np.ndarray | None":
    """Decode arbitrary compressed audio to 16 kHz mono via ffmpeg.

    ffmpeg rather than `datasets`' own decoding, deliberately. datasets 5.x
    delegates audio decode to torchcodec, whose wheels are built per-CUDA and
    resolve to one wanting libnvrtc.so.13 against this CUDA 12.1 image.
    Pinning the notebook's old datasets instead drags in pyarrow<15 and
    numpy<2 — a 2023 stack fighting this image's numpy 2.1.

    ffmpeg is already here for Piper, handles flac/mp3/wav/ogg alike, and has
    no opinion about torch versions. It sidesteps the whole problem class.
    """
    try:
        proc = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error",
             "-i", "pipe:0",
             "-f", "s16le", "-acodec", "pcm_s16le",
             "-ac", "1", "-ar", "16000", "pipe:1"],
            input=raw, capture_output=True, check=True,
        )
    except (subprocess.CalledProcessError, OSError):
        return None
    if not proc.stdout:
        return None
    return np.frombuffer(proc.stdout, dtype=np.int16)


def parquet_rows(url: str) -> Iterator[dict]:
    """Stream a remote parquet a row group at a time, without downloading it whole."""
    import fsspec
    import pyarrow.parquet as pq

    with fsspec.open(url).open() as handle:
        parquet = pq.ParquetFile(handle)
        for group in range(parquet.num_row_groups):
            for row in parquet.read_row_group(group).to_pylist():
                yield row


def prepare_rirs() -> Path:
    """Room impulse responses, for training with realistic echo."""
    out = DATA / "mit_rirs"
    if out.exists() and any(out.glob("*.wav")):
        print(f"RIRs already present at {out}")
        return out
    out.mkdir(parents=True, exist_ok=True)

    repo = DATA / "MIT_environmental_impulse_responses"
    if not repo.exists():
        run(["git", "clone", "--depth", "1",
             "https://huggingface.co/datasets/davidscripka/MIT_environmental_impulse_responses",
             str(repo)])

    sources = sorted((repo / "16khz").glob("*.wav"))
    for source in tqdm(sources, desc="RIRs -> 16 kHz wav"):
        samples = decode_to_16k_mono(source.read_bytes())
        if samples is None:
            continue
        scipy.io.wavfile.write(out / source.name, 16000, samples)
    return out


def prepare_audioset(clips: int = 1200) -> Path:
    """A slice of AudioSet as background noise.

    The notebook fetched `data/bal_train09.tar` and globbed flacs out of it;
    that 404s, because the dataset was repacked into 38 parquet shards under
    `data/bal_train/`. Audio arrives as `struct<bytes, path>`, decoded here
    with ffmpeg — see decode_to_16k_mono for why not `datasets`.
    """
    out = DATA / "audioset_16k"
    if out.exists() and len(list(out.glob("*.wav"))) >= clips // 2:
        print(f"AudioSet already present at {out}")
        return out
    out.mkdir(parents=True, exist_ok=True)

    base = ("https://huggingface.co/datasets/agkphysics/AudioSet"
            "/resolve/main/data/bal_train")

    written = 0
    shard = 0
    with tqdm(total=clips, desc="AudioSet -> 16 kHz wav") as progress:
        while written < clips and shard < 38:
            for row in parquet_rows(f"{base}/{shard:02d}.parquet"):
                audio = row.get("audio") or {}
                samples = decode_to_16k_mono(audio.get("bytes") or b"")
                if samples is None or samples.size < 16000:
                    continue
                name = str(audio.get("path") or f"clip_{written}").split("/")[-1]
                scipy.io.wavfile.write(
                    out / (name.rsplit(".", 1)[0] + ".wav"), 16000, samples
                )
                written += 1
                progress.update(1)
                if written >= clips:
                    break
            shard += 1

    if written == 0:
        raise SystemExit(
            "No AudioSet clips could be decoded. Check the layout at "
            "https://huggingface.co/datasets/agkphysics/AudioSet/tree/main/data"
        )
    print(f"Wrote {written} background clips to {out}")
    return out


def prepare_music(hours: int = 1) -> Path | None:
    """Music as a second kind of background — harder negatives than noise.

    Optional: returns None if it can't be fetched. Noise augmentation plus the
    2,000 hours of pre-computed negative features carry most of the weight, so
    a music outage shouldn't block a training run.
    """
    out = DATA / "fma"
    if out.exists() and any(out.glob("*.wav")):
        print(f"Music already present at {out}")
        return out
    out.mkdir(parents=True, exist_ok=True)

    clips = hours * 3600 // 30  # the FMA small set is all 30-second clips
    url = ("https://huggingface.co/datasets/rudraml/fma/resolve/refs%2Fconvert"
           "%2Fparquet/small/train/0000.parquet")

    written = 0
    try:
        with tqdm(total=clips, desc="Music -> 16 kHz wav") as progress:
            for row in parquet_rows(url):
                audio = row.get("audio") or {}
                samples = decode_to_16k_mono(audio.get("bytes") or b"")
                if samples is None or samples.size < 16000:
                    continue
                name = str(audio.get("path") or f"music_{written}").split("/")[-1]
                scipy.io.wavfile.write(
                    out / (name.rsplit(".", 1)[0] + ".wav"), 16000, samples
                )
                written += 1
                progress.update(1)
                if written >= clips:
                    break
    except Exception as error:
        print(f"Music download skipped ({error}); continuing with noise only.")

    if written == 0:
        return None
    print(f"Wrote {written} music clips to {out}")
    return out


def prepare_features() -> tuple[Path, Path]:
    """Pre-computed negative features: ~2,000 hours train, ~11 hours validation."""
    train = DATA / "openwakeword_features_ACAV100M_2000_hrs_16bit.npy"
    val = DATA / "validation_set_features.npy"
    base = "https://huggingface.co/datasets/davidscripka/openwakeword_features/resolve/main/"
    for path in (train, val):
        if not path.exists():
            run(["wget", "-O", str(path), base + path.name])
    return train, val


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Train a custom openWakeWord model on a local GPU.")
    parser.add_argument("phrase",
                        help="wake phrase, phonetic, underscores between parts "
                             "(e.g. hey_ass_trul)")
    parser.add_argument("--samples", type=int, default=30000,
                        help="synthetic examples to generate. The notebook "
                             "defaults to 1000 and says 30000-50000 is often "
                             "best; on a local GPU there's no reason to take "
                             "the small one. (default: %(default)s)")
    parser.add_argument("--steps", type=int, default=50000,
                        help="training steps (default: %(default)s)")
    parser.add_argument("--false-activation-penalty", type=int, default=1500,
                        help="higher means fewer false wakes, but a model that "
                             "needs the phrase said more clearly "
                             "(default: %(default)s)")
    parser.add_argument("--music-hours", type=int, default=1)
    parser.add_argument(
        "--stages", default="generate,augment,train",
        help="comma-separated subset of generate,augment,train. Clip "
             "generation and augmentation write ~2.4 GB under the output "
             "directory and take most of the wall clock, so a failure in the "
             "training stage shouldn't mean redoing them. "
             "(default: %(default)s)")
    args = parser.parse_args()

    phrase = validate_phrase(args.phrase)
    model_name = phrase.replace(" ", "_")

    DATA.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)

    print(f"=== phrase: {phrase!r}  ->  model name: {model_name!r} ===")

    audioset = prepare_audioset()
    music = prepare_music(args.music_hours)
    prepare_rirs()
    train_features, val_features = prepare_features()

    config = yaml.safe_load((OWW / "examples" / "custom_model.yml").read_text())
    config.update({
        "target_phrase": [phrase],
        "model_name": model_name,
        "n_samples": args.samples,
        "n_samples_val": max(500, args.samples // 10),
        "steps": args.steps,
        "target_accuracy": 0.5,
        "target_recall": 0.25,
        "output_dir": str(OUT),
        "max_negative_weight": args.false_activation_penalty,
        "background_paths": [str(p) for p in (audioset, music) if p is not None],
        "false_positive_validation_data_path": str(val_features),
        "feature_data_files": {"ACAV100M_sample": str(train_features)},
        "rir_paths": [str(DATA / "mit_rirs")],
    })

    config_path = OUT / f"{model_name}.yaml"
    config_path.write_text(yaml.dump(config))
    print(f"Wrote training config to {config_path}")

    trainer = str(OWW / "openwakeword" / "train.py")
    requested = {s.strip() for s in args.stages.split(",") if s.strip()}
    stages = [
        ("generate", "--generate_clips"),
        ("augment", "--augment_clips"),
        ("train", "--train_model"),
    ]
    onnx_model = OUT / f"{model_name}.onnx"
    for name, flag in stages:
        if name not in requested:
            print(f"Skipping {name} (not in --stages)")
            continue
        try:
            run([sys.executable, trainer, "--training_config",
                 str(config_path), flag])
        except subprocess.CalledProcessError:
            # openWakeWord's trainer writes the .onnx and *then* tries to
            # export tflite through `onnx_tf`, which is abandoned and needs an
            # ancient TensorFlow — so it exits non-zero having already
            # produced the model we want. Treat that as success and let the
            # onnx2tf conversion below do the export, which is exactly what
            # the upstream notebook does.
            if name == "train" and onnx_model.exists():
                print(f"\nTrainer exited non-zero but {onnx_model.name} was "
                      "written — continuing to the tflite conversion.")
                continue
            raise

    # ONNX -> tflite. `-kat onnx____Flatten_0` names the graph input to keep as
    # a channel-last tensor; it's the input openWakeWord's exporter produces.
    if not onnx_model.exists():
        raise SystemExit(f"Training finished but {onnx_model} is missing.")

    run(["onnx2tf", "-i", str(onnx_model), "-o", str(OUT),
         "-kat", "onnx____Flatten_0"])

    float32 = OUT / f"{model_name}_float32.tflite"
    final = OUT / f"{model_name}.tflite"
    if float32.exists():
        os.replace(float32, final)

    print("\n=== done ===")
    for path in (onnx_model, final):
        if path.exists():
            print(f"  {path}  ({path.stat().st_size / 1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
