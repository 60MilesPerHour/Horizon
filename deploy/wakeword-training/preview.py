#!/usr/bin/env python
"""Generate sample clips of one or more candidate spellings.

Takes several phrases in one go deliberately: the Piper model takes ~10 s to
load, and comparing spellings is inherently an A/B exercise, so reloading per
candidate wastes most of the time.

Worth doing every time the phrase changes. Training runs for the better part
of an hour and will faithfully learn a mispronunciation.
"""
import argparse
import sys

sys.path.append("/work/piper-sample-generator")
from generate_samples import generate_samples  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("phrases", nargs="+",
                        help="candidate spellings, e.g. hey_astral hey_as_truhl")
    parser.add_argument("--variants", type=int, default=1,
                        help="clips per phrase, with different speakers/speeds "
                             "(default: %(default)s)")
    args = parser.parse_args()

    for phrase in args.phrases:
        for n in range(args.variants):
            name = phrase if args.variants == 1 else f"{phrase}__{n + 1}"
            generate_samples(
                text=phrase,
                max_samples=1,
                # Slight variation per clip so a single unlucky rendering
                # doesn't get a spelling rejected.
                length_scales=[1.1 + 0.08 * n],
                noise_scales=[0.7],
                noise_scale_ws=[0.7],
                output_dir="/out",
                batch_size=1,
                auto_reduce_batch_size=True,
                file_names=[f"{name}.wav"],
            )
            print(f"  -> /out/{name}.wav")

    print("\nListen to them before committing to a training run.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
