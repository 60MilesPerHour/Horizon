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


def prepare_rirs() -> Path:
    """Room impulse responses, for training with realistic echo."""
    out = DATA / "mit_rirs"
    if out.exists() and any(out.glob("*.wav")):
        print(f"RIRs already present at {out}")
        return out
    out.mkdir(parents=True, exist_ok=True)

    repo = DATA / "MIT_environmental_impulse_responses"
    if not repo.exists():
        run(["git", "clone",
             "https://huggingface.co/datasets/davidscripka/MIT_environmental_impulse_responses",
             str(repo)])

    import datasets
    ds = datasets.Dataset.from_dict(
        {"audio": [str(p) for p in (repo / "16khz").glob("*.wav")]}
    ).cast_column("audio", datasets.Audio())
    for row in tqdm(ds, desc="RIRs -> 16-bit wav"):
        name = row["audio"]["path"].split("/")[-1]
        scipy.io.wavfile.write(
            out / name, 16000, (row["audio"]["array"] * 32767).astype(np.int16)
        )
    return out


def prepare_audioset() -> Path:
    """A slice of AudioSet as background noise."""
    out = DATA / "audioset_16k"
    if out.exists() and any(out.glob("*.wav")):
        print(f"AudioSet already present at {out}")
        return out
    out.mkdir(parents=True, exist_ok=True)

    tar_dir = DATA / "audioset"
    tar_dir.mkdir(parents=True, exist_ok=True)
    tar = tar_dir / "bal_train09.tar"
    if not tar.exists():
        run(["wget", "-O", str(tar),
             "https://huggingface.co/datasets/agkphysics/AudioSet/resolve/main/data/bal_train09.tar"])
    run(["tar", "-xf", str(tar), "-C", str(tar_dir)])

    import datasets
    ds = datasets.Dataset.from_dict(
        {"audio": [str(p) for p in (tar_dir / "audio").glob("**/*.flac")]}
    ).cast_column("audio", datasets.Audio(sampling_rate=16000))
    for row in tqdm(ds, desc="AudioSet -> 16-bit wav"):
        name = row["audio"]["path"].split("/")[-1].replace(".flac", ".wav")
        scipy.io.wavfile.write(
            out / name, 16000, (row["audio"]["array"] * 32767).astype(np.int16)
        )
    return out


def prepare_music(hours: int = 1) -> Path:
    """Music as a second kind of background — harder negatives than noise."""
    out = DATA / "fma"
    if out.exists() and any(out.glob("*.wav")):
        print(f"Music already present at {out}")
        return out
    out.mkdir(parents=True, exist_ok=True)

    import datasets
    ds = datasets.load_dataset("rudraml/fma", name="small", split="train", streaming=True)
    ds = iter(ds.cast_column("audio", datasets.Audio(sampling_rate=16000)))
    clips = hours * 3600 // 30  # the FMA small set is all 30-second clips
    for _ in tqdm(range(clips), desc="Music -> 16-bit wav"):
        row = next(ds)
        name = row["audio"]["path"].split("/")[-1].replace(".mp3", ".wav")
        scipy.io.wavfile.write(
            out / name, 16000, (row["audio"]["array"] * 32767).astype(np.int16)
        )
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
        "background_paths": [str(audioset), str(music)],
        "false_positive_validation_data_path": str(val_features),
        "feature_data_files": {"ACAV100M_sample": str(train_features)},
        "rir_paths": [str(DATA / "mit_rirs")],
    })

    config_path = OUT / f"{model_name}.yaml"
    config_path.write_text(yaml.dump(config))
    print(f"Wrote training config to {config_path}")

    trainer = str(OWW / "openwakeword" / "train.py")
    for stage in ("--generate_clips", "--augment_clips", "--train_model"):
        run([sys.executable, trainer, "--training_config", str(config_path), stage])

    # ONNX -> tflite. `-kat onnx____Flatten_0` names the graph input to keep as
    # a channel-last tensor; it's the input openWakeWord's exporter produces.
    onnx_model = OUT / f"{model_name}.onnx"
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
