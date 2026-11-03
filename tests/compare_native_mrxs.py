"""Run a private real-sample check against the independent Python region probe."""

import json
from pathlib import Path
import subprocess
import sys

import numpy as np

from mrxs_probe.probe import decode
from mrxs_probe.region import ExperimentalRegionReader


root = Path(sys.argv[1]).resolve()
entry = Path(sys.argv[2]).resolve()
reader = ExperimentalRegionReader(entry, slot_order="reversed")
shared = set.intersection(*(set(table) for table in reader.tables.values()))
nx = reader.index.nx
corners = [key for key in sorted(shared) if key % nx < nx - 1
           and all(key + d in shared for d in (1, nx, nx + 1))]
rng = np.random.default_rng(20261103)
rects = [
    [int((k % nx + 1) * reader.tile_width - 40), int((k // nx + 1) * reader.tile_height - 40), 80, 80]
    for k in rng.choice(corners, 10, replace=False)
]
plan = [[0, *rect] for rect in rects]
expected = [reader.read_region(*rect).ravel() for rect in rects]
seam_samples = sum(pixels.size for pixels in expected)
tw, th = reader.tile_width, reader.tile_height
for level, descriptor in enumerate(reader.metadata["pyramid_levels"][1:], start=1):
    step = 2**level
    streams = {group: reader.index.records(group, level) for group in reader.groups}
    common = set.intersection(*(set(stream) for stream in streams.values()))
    key = min(common)
    x, y = (key % nx // step) * tw, (key // nx // step) * th
    w, h = min(20, reader.width // step - x), min(20, reader.height // step - y)
    assert w > 0 and h > 0
    pixels = np.empty((len(reader.channels), h, w), dtype=np.uint8)
    for group, channels in reader.groups.items():
        tile, _, _ = decode(reader.index.payload(streams[group][key]), descriptor)
        for channel, component in channels:
            pixels[channel] = tile[:h, :w, component]
    plan.append([level, x, y, w, h])
    expected.append(pixels.ravel())

(root / "mrxs-plan.json").write_text(json.dumps(plan))
subprocess.run([root / "regression", root, entry], check=True)
actual = np.fromfile(root / "mrxs-observed.bin", dtype=np.uint8)
delta = np.abs(np.concatenate(expected).astype(np.int16) - actual)
for label, values in (("level-0 seams", delta[:seam_samples]), ("pyramid levels", delta[seam_samples:])):
    if values.size:
        assert values.max() <= 1
        print(f"Native MRXS {label}: {values.size} samples, {np.mean(values == 0):.4%} exact, max difference {values.max()}.")
