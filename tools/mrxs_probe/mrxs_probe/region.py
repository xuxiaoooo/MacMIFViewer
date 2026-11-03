"""Experimental level-0 reads for the audited regular-grid MRXS variant."""

import argparse
from collections import defaultdict
import configparser
import json
from pathlib import Path
import sys

import numpy as np

from .layout import ProbeError, read_metadata, require
from .probe import decode, summarize


class ExperimentalRegionReader:
    def __init__(self, entry, *, slot_order):
        require(slot_order in ("direct", "reversed"), "InvalidSlotOrder", "Specify a candidate slot order.")
        self.metadata = {}
        self.index = read_metadata(entry, self.metadata, require_regular_grid=True)
        self.level = self.metadata["pyramid_levels"][0]
        require(self.level["metadata_codec"] == "JPEG"
                and self.metadata["claimed_source_bit_depth"] == 8,
                "UnsupportedCodec", "Experimental regions require a declared 8-bit JPEG level.")
        self.tile_width = self.level["tile_width"]
        self.tile_height = self.level["tile_height"]
        self.width = self.tile_width * self.index.nx
        self.height = self.tile_height * self.index.ny
        self.channels = self.metadata["channels"]
        self.groups = defaultdict(list)
        for channel in self.channels:
            slot = channel["channel_index_in_source"]
            require(slot in (0, 1, 2), "MissingComponent", "Storage slot is outside the packed JPEG components.")
            if slot_order == "reversed":
                slot = 2 - slot
            self.groups[channel["channel_source_filter_level"]].append((channel["channel"], slot))
        self.tables = {group: self.index.records(group, 0) for group in self.groups}
        require(all(self.tables.values()), "MissingTileStream", "A mapped level-0 storage group has no records.")

    def read_region(self, x, y, width, height):
        require(0 <= x and 0 <= y and 0 < width <= 512 and 0 < height <= 512
                and x + width <= self.width and y + height <= self.height,
                "InvalidRegion", "Region must be inside the candidate level-0 grid and at most 512×512.")
        region = np.empty((len(self.channels), height, width), dtype=np.uint8)
        tw, th = self.tile_width, self.tile_height
        for row in range(y // th, (y + height - 1) // th + 1):
            top = row * th
            y0, y1 = max(y, top), min(y + height, top + th)
            for col in range(x // tw, (x + width - 1) // tw + 1):
                left = col * tw
                x0, x1 = max(x, left), min(x + width, left + tw)
                key = row * self.index.nx + col
                for group, channels in self.groups.items():
                    record = self.tables[group].get(key)
                    require(record is not None, "MissingRegionTile", "Region intersects a missing tile.")
                    try:
                        tile, codec, precision = decode(self.index.payload(record), self.level)
                    except (RuntimeError, ValueError, OSError, NotImplementedError) as error:
                        raise ProbeError("DecodeFailed", "A region tile failed to decode.") from error
                    require(codec == "JPEG" and precision == 8 and tile.dtype == np.uint8 and tile.shape[2] == 3,
                            "UnsupportedComponentLayout", "Region requires packed 8-bit three-component JPEG tiles.")
                    for channel, slot in channels:
                        region[channel, y0-y:y1-y, x0-x:x1-x] = tile[y0-top:y1-top, x0-left:x1-left, slot]
        return region


def main():
    parser = argparse.ArgumentParser(description="Report an experimental MRXS region without writing source pixels.")
    parser.add_argument("entry", type=Path)
    parser.add_argument("--xywh", type=int, nargs=4, required=True, metavar=("X", "Y", "W", "H"))
    parser.add_argument("--slot-order", choices=("direct", "reversed"), required=True)
    args = parser.parse_args()
    try:
        reader = ExperimentalRegionReader(args.entry, slot_order=args.slot_order)
        region = reader.read_region(*args.xywh)
    except ProbeError as error:
        print(f"{error.code}: {error}", file=sys.stderr)
        return 2
    except (configparser.Error, KeyError, ValueError, OSError, OverflowError):
        print("InvalidSource: required input metadata or files could not be read.", file=sys.stderr)
        return 2
    print(json.dumps({
        "status": "experimental_candidate_grid",
        "region_xywh": args.xywh,
        "candidate_grid_width": reader.width,
        "candidate_grid_height": reader.height,
        "slot_order": args.slot_order,
        "dtype": region.dtype.name,
        "channels": [{"candidate_name": channel["channel_name"], **summarize(plane)}
                     for channel, plane in zip(reader.channels, region, strict=True)],
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
