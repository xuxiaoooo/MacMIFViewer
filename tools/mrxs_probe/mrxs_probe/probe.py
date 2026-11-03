"""Sample encoded tile components without assembling a slide or changing pixels."""

from collections import defaultdict
import configparser
import hashlib
import importlib.metadata
import platform
import random
import struct

import imagecodecs as codecs
import numpy as np
import tifffile

from .layout import ProbeError, read_metadata, require


def jpeg_header(payload):
    pos, frame, adobe_transform = 2, None, None
    legacy_encoder = False
    direct_sampling = False
    while pos + 4 <= len(payload) and payload[pos] == 0xFF:
        marker = payload[pos + 1]
        if marker in (0xDA, 0xD9):
            break
        if marker == 0xFF:
            pos += 1
            continue
        length = int.from_bytes(payload[pos + 2:pos + 4], "big")
        require(length >= 2 and pos + 2 + length <= len(payload), "InvalidTile",
                "Invalid JPEG segment length.")
        segment = payload[pos + 4:pos + 2 + length]
        if marker == 0xEE and segment.startswith(b"Adobe") and len(segment) >= 12:
            adobe_transform = segment[11]
        if marker == 0xFE and segment.startswith(b"Intel(R) IPP JPEG encoder"):
            legacy_encoder = True
        if marker in (0xC0, 0xC1, 0xC2) and len(segment) >= 6:
            frame = struct.unpack_from(">BHHB", segment)
            direct_sampling = len(segment) == 15 and segment[7::3] == b"\x11" * 3
        pos += 2 + length
    require(frame is not None, "UnsupportedCodec", "Unsupported JPEG frame type.")
    precision, height, width, components = frame
    require(precision in (8, 12) and
            (components == 1 or components == 3 and adobe_transform == 0 and legacy_encoder and direct_sampling),
            "UnsupportedComponentLayout", "JPEG components do not have a supported direct mapping.")
    return precision, height, width, components


def decode(payload, level):
    w, h = level["tile_width"], level["tile_height"]
    declared = level["metadata_codec"].replace("-", "").replace(" ", "")
    if payload.startswith(b"\xff\xd8"):
        require(declared == "JPEG", "CodecMismatch", "Indexed JPEG differs from level metadata.")
        precision, height, width, components = jpeg_header(payload)
        require((width, height) == (w, h), "TileShapeMismatch", "Unexpected JPEG frame dimensions.")
        # Request the stored color space. No YCbCr conversion or synthetic channel expansion.
        image = codecs.jpeg_decode(payload, colorspace="RGB", outcolorspace="RGB") if components == 3 \
            else codecs.jpeg_decode(payload)
        codec = "JPEG"
    elif payload.startswith((b"II\xbc\x01", b"MM\x01\xbc")):
        require(declared in {"JPEGXR", "JXR", "HDP", "WDP"}, "CodecMismatch",
                "Indexed JPEG XR differs from level metadata.")
        require(codecs.JPEGXR.available, "UnsupportedCodec", "JPEG XR decoder unavailable.")
        # JPEG XR image decode is intentionally limited to grayscale. A decoded dtype
        # alone does not establish the encoded precision or the scanner's raw bit depth.
        image = codecs.jpegxr_decode(payload)
        precision, components, codec = None, 1, "JPEG XR"
        require(image.ndim == 2, "UnsupportedComponentLayout",
                "Packed JPEG XR components require independent mapping validation.")
    else:
        raise ProbeError("UnsupportedCodec", "Indexed tile payload has an unsupported signature.")

    shape = (h, w) if components == 1 else (h, w, components)
    require(image.shape == shape and image.dtype in (np.uint8, np.uint16),
            "TileShapeMismatch", "Decoded tile shape or dtype differs from the expected representation.")
    return image.reshape(h, w, components), codec, precision


def summarize(plane):
    return dict(
        minimum=int(plane.min()), maximum=int(plane.max()),
        nonzero_fraction=float(np.count_nonzero(plane) / plane.size),
        p01_p50_p99=np.percentile(plane, [1, 50, 99]).tolist(),
        sha256=hashlib.sha256(plane.astype(plane.dtype.newbyteorder("<"), copy=False).tobytes()).hexdigest(),
    )


def diagnostics():
    info = {name: importlib.metadata.version(name) for name in ("numpy", "tifffile", "imagecodecs")}
    info.update(python=platform.python_version(), architecture=platform.machine(),
                macos=platform.mac_ver()[0], jpegxr_available=bool(codecs.JPEGXR.available))
    if info["jpegxr_available"]:
        try:
            array = np.arange(256, dtype=np.uint16).reshape(16, 16) * 257
            result = codecs.jpegxr_decode(codecs.jpegxr_encode(array))
            info["jpegxr_uint16_synthetic_roundtrip"] = bool(
                result.dtype == array.dtype and np.array_equal(result, array))
        except (RuntimeError, ValueError, NotImplementedError):
            info["jpegxr_uint16_synthetic_roundtrip"] = False
    return info


def sample_tiles(index, report, roi_dir):
    groups = defaultdict(list)
    for channel in report["channels"]:
        groups[channel["channel_source_filter_level"]].append(channel)
    level0_hits = set()
    rng = random.Random(20261103)
    codecs_seen = set()
    for level in report["pyramid_levels"]:
        number = level["level"]
        tables = {}
        for group in groups:
            try:
                records = index.records(group, number)
                require(bool(records), "MissingTileStream", "No tile records in the mapped stream.")
                tables[group] = records
            except ProbeError as error:
                add_issue(report, error, group, number)
        level["tile_counts_by_storage_group"] = {group: len(table) for group, table in tables.items()}
        common = set.intersection(*(set(table) for table in tables.values())) if tables else set()
        level["common_index_positions"] = len(common) if len(tables) == len(groups) else 0
        if len(tables) == len(groups) and not common:
            add_issue(report, ProbeError("NoSharedIndexPositions", "Storage groups have no common index positions."),
                      level=number)
        shared = rng.sample(sorted(common), min(10, len(common)))
        neighbors = None
        if number == 0:
            neighbors = next(((k, k + 1) for k in shared
                              if k % index.nx < index.nx - 1 and k + 1 in common), None)
            if neighbors:
                shared = list(dict.fromkeys([*shared, *neighbors]))
                level["sampled_horizontal_index_neighbors"] = list(neighbors)
        for group, records in tables.items():
            slots = {channel["channel_index_in_source"] for channel in groups[group]}
            keys = shared or rng.sample(sorted(records), min(10, len(records)))
            for key in keys:
                try:
                    tile, codec, precision = decode(index.payload(records[key]), level)
                    codecs_seen.add(codec)
                except ProbeError as error:
                    add_issue(report, error, group, number, key)
                    continue
                except (ValueError, RuntimeError, NotImplementedError, OSError):
                    add_issue(report, ProbeError("DecodeFailed", "Tile payload could not be decoded."),
                              group, number, key)
                    continue
                if number == 0:
                    unmapped = level.setdefault("unmapped_component_sample_maxima", {}).setdefault(group, {})
                    for slot in set(range(tile.shape[2])) - slots:
                        unmapped[slot] = max(unmapped.get(slot, 0), int(tile[:, :, slot].max()))
                for channel in groups[group]:
                    slot = channel["channel_index_in_source"]
                    if slot >= tile.shape[2]:
                        add_issue(report, ProbeError("MissingComponent", "Requested component is absent."),
                                  group, number, key)
                        continue
                    plane = tile[:, :, slot]
                    sample = dict(level=number, tile_index=key, index_x=key % index.nx,
                                  index_y=key // index.nx, codec=codec,
                                  encoded_sample_precision_bits=precision,
                                  component_mapping="candidate_rgb_slot" if tile.shape[2] == 3 else "grayscale",
                                  sample_dtype=plane.dtype.name, **summarize(plane))
                    if number == 0 and tile.shape[2] == 3 and slot != 1:
                        sample["reversed_slot_candidate"] = summarize(tile[:, :, 2 - slot])
                    channel["samples"].append(sample)
                    if number != 0:
                        continue
                    level0_hits.add(channel["channel"])
                    if roi_dir is not None and key == keys[0]:
                        height, width = plane.shape
                        x, y = width // 4, height // 4
                        crop = plane[y:y + 64, x:x + 64]
                        name = f"channel-{channel['channel']:02d}-tile-{key}.tif"
                        with (roi_dir / name).open("xb") as output:
                            tifffile.imwrite(output, crop, photometric="minisblack", metadata=None)
                        sample["diagnostic_crop"] = dict(
                            file=name, tile_local_xywh=[x, y, crop.shape[1], crop.shape[0]], **summarize(crop))
    report["compression_detected"] = sorted(codecs_seen)
    for channel in report["channels"]:
        samples = channel["samples"]
        if samples and all(sample["maximum"] == 0 for sample in samples):
            report["warnings"].append(
                f"Channel {channel['channel']} is all zero in the sampled component. Verify the mapping against an official ROI.")
        dtypes = {s["sample_dtype"] for s in samples}
        if len(dtypes) == 1:
            channel["sample_dtype"] = next(iter(dtypes))
        elif dtypes:
            add_issue(report, ProbeError("MixedDtype", "Sample dtype varies within a channel."),
                      channel["channel_source_filter_level"])
    report["verified_decodable_channel_count"] = len(level0_hits)
    if level0_hits:
        report["read_support_status"] = "experimental_tile_samples"


def add_issue(report, error, group=None, level=None, tile_index=None):
    report["unsupported_reasons"].append(dict(code=error.code, message=str(error),
                                               group=group, level=level, tile_index=tile_index))


def inspect(entry, roi_dir=None):
    report = dict(
        slide_id_anonymized="slide-01", source_type="MRXS", file_layout_valid=False,
        width=None, height=None, physical_pixel_size_x_um=None, physical_pixel_size_y_um=None,
        compression_detected=[], pyramid_levels=[], metadata_channel_count=None,
        verified_decodable_channel_count=0, channels=[], claimed_source_bit_depth=None,
        verified_raw_bit_depth=None, z_slices=None, scanner_version_if_available=None,
        read_support_status="unsupported", unsupported_reasons=[],
        warnings=[
            "Tile index coordinates are not stitched level-0 coordinates.",
            "Decoded component precision is not independently verified scanner raw bit depth.",
            "Packed JPEG slot-to-component order is a candidate mapping pending independent validation.",
        ],
        diagnostic_versions=diagnostics(),
    )
    try:
        index = read_metadata(entry, report)
        sample_tiles(index, report, roi_dir)
    except ProbeError as error:
        add_issue(report, error)
    except (configparser.Error, KeyError, ValueError, UnicodeError, OverflowError):
        add_issue(report, ProbeError("InvalidMetadata", "Required metadata is malformed or missing."))
    except OSError:
        add_issue(report, ProbeError("IOError", "A source read or diagnostic crop write failed."))
    add_issue(report, ProbeError("ReferenceValidationMissing",
                                 "Slide geometry and component identity require official reference ROIs."))
    return report
