"""Compare ten deterministically sampled four-tile seam ROIs with the Rust reader."""

import argparse
import json
from pathlib import Path
import random
import subprocess

import numpy as np

from mrxs_probe.region import ExperimentalRegionReader


def compare(entry, oracle):
    reader = ExperimentalRegionReader(entry, slot_order="reversed")
    shared = set.intersection(*(set(table) for table in reader.tables.values()))
    nx = reader.index.nx
    corners = [key for key in sorted(shared) if key % nx < nx - 1
               and all(key + delta in shared for delta in (1, nx, nx + 1))]
    if min(reader.tile_width, reader.tile_height) < 40 or len(corners) < 10:
        raise RuntimeError("Ten four-tile seam regions could not be selected.")
    rois = [((key % nx + 1) * reader.tile_width - 40, (key // nx + 1) * reader.tile_height - 40, 80, 80)
            for key in random.Random(20261103).sample(corners, 10)]
    request = "".join(" ".join(map(str, roi)) + "\n" for roi in rois).encode()
    try:
        result = subprocess.run([oracle, entry], input=request, capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError("Rust comparison process could not complete.") from None
    python_pixels = np.stack([reader.read_region(*roi) for roi in rois])
    if result.returncode != 0 or len(result.stdout) != python_pixels.size:
        raise RuntimeError("Rust backend failed or returned an unexpected region size.")
    rust_pixels = np.frombuffer(result.stdout, dtype=np.uint8).reshape(python_pixels.shape)
    delta = np.abs(python_pixels.astype(np.int16) - rust_pixels)
    return {
        "status": "experimental_crosscheck",
        "backend_comparison": "imagecodecs vs openslide-pure-rs cde6ea16c49ea60229172e74f4e1abfe0743fa25",
        "coordinate_space": "candidate regular level-0 grid",
        "slot_order": "reversed",
        "verified_against_vendor": False,
        "roi_xywh": rois,
        "compared_pixels": delta.size,
        "maximum_absolute_difference": int(delta.max()),
        "exact_fraction": float(np.mean(delta == 0)),
        "channels": [
            {
                "candidate_name": meta["channel_name"],
                "maximum_absolute_difference": int(delta[:, c].max()),
                "mean_absolute_difference": float(delta[:, c].mean()),
            }
            for c, meta in enumerate(reader.channels)
        ],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("entry", type=Path)
    parser.add_argument("oracle", type=Path)
    args = parser.parse_args()
    print(json.dumps(compare(args.entry, args.oracle), ensure_ascii=False, indent=2))
