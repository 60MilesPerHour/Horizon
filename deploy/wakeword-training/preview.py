#!/usr/bin/env python
"""Generate one sample of the wake phrase so you can hear it before training.

Worth doing every time you change the phrase. Training runs for the better
part of an hour, and the single most common way to waste that is a phrase
Piper mispronounces — the model learns the wrong sounds perfectly well.
"""
import argparse
import sys

sys.path.append("/work/piper-sample-generator")
from generate_samples import generate_samples  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("phrase", help="wake phrase, e.g. hey_ass_trul")
    parser.add_argument("--out", default="/out/preview.wav")
    args = parser.parse_args()

    generate_samples(
        text=args.phrase,
        max_samples=1,
        length_scales=[1.1],
        noise_scales=[0.7],
        noise_scale_ws=[0.7],
        output_dir="/out",
        batch_size=1,
        auto_reduce_batch_size=True,
        file_names=[args.out.split("/")[-1]],
    )
    print(f"\nWrote {args.out} — listen to it before committing to a training run.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
