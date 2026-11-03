"""Read metadata and bounded index records for the tested fluorescence layout."""

import configparser
from dataclasses import dataclass
from math import isfinite
from pathlib import Path
import re
import struct


class ProbeError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def require(condition: bool, code: str, message: str):
    if not condition:
        raise ProbeError(code, message)


def positive_scale(section, key):
    if key not in section:
        return None
    value = float(section[key])
    return value if isfinite(value) and value > 0 else None


def source_file(sidecar, name, role):
    require(Path(name).name == name, "InvalidLayout", f"{role} must be a local file.")
    path = sidecar / name
    require(path.resolve().parent == sidecar.resolve(), "InvalidLayout",
            f"{role} resolves outside the sidecar.")
    require(path.is_file() and path.stat().st_size > 0, "MissingSourceFile",
            f"{role} is missing or empty.")
    return path


def read_metadata(entry, report, *, require_regular_grid=False):
    require(entry.suffix.lower() == ".mrxs" and entry.is_file()
            and entry.stat().st_size > 0, "InvalidEntry",
            "Provide an existing nonempty .mrxs entry file.")
    sidecar = entry.with_suffix("")
    require(sidecar.is_dir(), "MissingSidecar", "Same-stem sidecar directory is missing.")
    ini = configparser.ConfigParser(interpolation=None)
    path = source_file(sidecar, "Slidedat.ini", "Slidedat.ini")
    require(path.stat().st_size <= 4 * 1024**2, "InvalidMetadata", "INI exceeds probe limit.")
    with path.open(encoding="utf-8-sig") as stream:
        ini.read_file(stream, source="Slidedat.ini")

    general = ini["GENERAL"]
    hierarchy = ini["HIERARCHICAL"]
    index_path = source_file(sidecar, hierarchy["INDEXFILE"], "Index file")
    files = ini["DATAFILE"]
    count = int(files["FILE_COUNT"])
    require(0 < count <= 4096, "InvalidMetadata", "Unsupported data file count.")
    paths = [source_file(sidecar, files[f"FILE_{i}"], f"Data file #{i}") for i in range(count)]
    report.update(file_layout_valid=True, data_file_count=count,
                  slide_format_version=general.get("SLIDE_VERSION"),
                  current_slide_version=general.get("CURRENT_SLIDE_VERSION"),
                  claimed_source_bit_depth=general.getint("VIMSLIDE_SLIDE_BITDEPTH"))

    hierarchy_count = int(hierarchy["HIER_COUNT"])
    require(0 < hierarchy_count <= 16, "InvalidMetadata", "Unsupported hierarchy count.")
    names = [hierarchy[f"HIER_{i}_NAME"].casefold() for i in range(hierarchy_count)]
    report["hierarchy_counts"] = {
        name: int(hierarchy[f"HIER_{i}_COUNT"]) for i, name in enumerate(names)
        if name in {"slide zoom level", "slide zoom mask level2", "slide filter level",
                    "microscope focus level"}
    }
    require(names == ["slide zoom level", "slide zoom mask level2", "slide filter level",
                      "microscope focus level"],
            "UnsupportedHierarchy", "Hierarchy order differs from the sampled index variant.")
    focus_count = int(hierarchy["HIER_3_COUNT"])
    report["focus_level_count"] = focus_count

    def sections(axis):
        count = int(hierarchy[f"HIER_{axis}_COUNT"])
        require(0 < count <= 32, "InvalidMetadata", "Unsupported hierarchy entry count.")
        return [ini[hierarchy[f"HIER_{axis}_VAL_{i}_SECTION"]] for i in range(count)]

    levels = []
    zoom_sections = sections(0)
    for i, section in enumerate(zoom_sections):
        w, h = int(section["DIGITIZER_WIDTH"]), int(section["DIGITIZER_HEIGHT"])
        require(0 < w <= 4096 and 0 < h <= 4096, "InvalidMetadata", "Invalid tile dimensions.")
        levels.append(dict(level=i, tile_width=w, tile_height=h,
                           metadata_codec=section["IMAGE_FORMAT"].upper(),
                           mpp_x=positive_scale(section, "MICROMETER_PER_PIXEL_X"),
                           mpp_y=positive_scale(section, "MICROMETER_PER_PIXEL_Y")))
    if require_regular_grid:
        base = zoom_sections[0]
        auxiliary_count = hierarchy.getint("NONHIER_COUNT", fallback=-1)
        require(0 <= auxiliary_count <= 16, "UnsupportedGeometry", "Unknown auxiliary layer layout.")
        auxiliary = {hierarchy.get(f"NONHIER_{i}_NAME", "").casefold() for i in range(auxiliary_count)}
        require(auxiliary <= {"vimslide_histogram_data", "scan data layer"}
                and general.getint("CameraImageDivisionsPerSide", fallback=1) == 1
                and general.getfloat("CAMERA_ROTATION", fallback=0) == 0
                and base.getfloat("OVERLAP_X", fallback=None) == 0
                and base.getfloat("OVERLAP_Y", fallback=None) == 0
                and base.getint("IMAGE_CONCAT_FACTOR", fallback=None) == 0,
                "UnsupportedGeometry", "Experimental region reads require an unrotated level-0 grid without overlap or position buffers.")
    sx, sy = levels[0]["mpp_x"], levels[0]["mpp_y"]
    for level in levels:
        x, y = level["mpp_x"], level["mpp_y"]
        level.update(downsample_x=x / sx if x and sx else None,
                     downsample_y=y / sy if y and sy else None)
    report.update(pyramid_levels=levels, physical_pixel_size_x_um=sx,
                  physical_pixel_size_y_um=sy)
    channels = []
    filter_sections = sections(2)
    for i, section in enumerate(filter_sections):
        match = re.fullmatch(r"FilterLevel_(\d+)", section["DATA_IN_THIS_FILTER_LEVEL"])
        require(match is not None, "UnsupportedFilterLevel", "Unknown storage group label.")
        group = int(match[1])
        slot = int(section["STORING_CHANNEL_NUMBER"])
        require(0 <= group < len(filter_sections) and 0 <= slot < 8, "UnsupportedFilterLevel",
                "Storage group or component is out of supported range.")
        channels.append(dict(channel=i, channel_name=section.get("FILTER_NAME"),
                             channel_source_filter_level=group, channel_index_in_source=slot,
                             metadata_zstack_step_count=section.getint("ZSTACK_STEP_COUNT"),
                             sample_dtype=None, verified_raw_bit_depth=None, samples=[]))
    report.update(channels=channels, metadata_channel_count=len(channels))
    mappings = {(c["channel_source_filter_level"], c["channel_index_in_source"])
                for c in channels}
    require(len(mappings) == len(channels), "AmbiguousChannels", "Duplicate component mapping.")
    focus_value = hierarchy.get("HIER_3_VAL_0", "")
    require(focus_count == 1 and focus_value == "ExtFocusLevel"
            and all(c["metadata_zstack_step_count"] == 0 for c in channels),
            "UnsupportedZStack", "Probe requires a single extended-focus image and explicit zero Z steps.")
    report["z_slices"] = 1
    require(hierarchy.getint("HIER_1_COUNT") == 2
            and hierarchy.get("HIER_1_VAL_0") == "ZoomMaskDefault"
            and hierarchy.get("HIER_1_VAL_1") == "ZoomMaskData",
            "UnsupportedHierarchy", "Unsupported zoom mask layout.")
    nx, ny = int(general["IMAGENUMBER_X"]), int(general["IMAGENUMBER_Y"])
    require(nx > 0 and ny > 0 and nx * ny <= 10_000_000, "InvalidMetadata", "Invalid tile grid.")
    report["metadata_index_grid"] = [nx, ny]
    return Index(index_path, general["SLIDE_ID"], paths, nx, ny, len(levels), len(filter_sections))


@dataclass(frozen=True)
class Record:
    offset: int
    length: int
    file_number: int


class Index:
    def __init__(self, path, slide_id, data_files, nx, ny, depth, filters):
        require(path.stat().st_size <= 64 * 1024**2, "UnsupportedIndex", "Index exceeds probe limit.")
        self.data = path.read_bytes()
        self.paths = data_files
        self.file_sizes = [p.stat().st_size for p in data_files]
        self.nx, self.ny, self.depth = nx, ny, depth
        self.hier_entries = 2 * depth * filters
        signature = b"01.02" + slide_id.encode("ascii")
        require(self.data.startswith(signature), "UnsupportedIndex",
                "Unknown index signature or entry identifier mismatch.")
        self.root, self.nonhier = self.ints(len(signature), 2)
        require(len(signature) + 8 <= self.root
                and self.root + 4 * self.hier_entries <= self.nonhier <= len(self.data),
                "CorruptIndex", "Invalid hierarchy table bounds.")

    def ints(self, offset, count):
        require(0 <= offset <= len(self.data) - count * 4, "CorruptIndex", "Index read out of bounds.")
        return struct.unpack_from(f"<{count}i", self.data, offset)

    def records(self, group, level):
        # Mixed radix: zoom varies fastest, then two mask values, then filter.
        slot = level + 2 * self.depth * group
        require(0 <= slot < self.hier_entries, "CorruptIndex", "Invalid stream slot.")
        location = self.root + 4 * slot
        (ptr,) = self.ints(location, 1)
        if not ptr:
            return {}
        zero, page = self.ints(ptr, 2)
        require(zero == 0 and page > 0, "CorruptIndex", "Invalid stream header.")
        records = {}
        seen = set()
        while page:
            require(page not in seen, "CorruptIndex", "Index page cycle.")
            seen.add(page)
            count, following = self.ints(page, 2)
            require(0 < count <= self.nx * self.ny - len(records), "CorruptIndex",
                    "Invalid index page record count.")
            require(page + 8 + count * 16 <= len(self.data), "CorruptIndex",
                    "Truncated index page.")
            for row in range(count):
                key, offset, length, file_number = self.ints(page + 8 + row * 16, 4)
                require(0 <= key < self.nx * self.ny and key not in records
                        and 0 <= file_number < len(self.paths)
                        and 0 < length <= 64 * 1024**2
                        and 0 <= offset <= self.file_sizes[file_number] - length,
                        "CorruptIndex", "Invalid or duplicate tile record.")
                records[key] = Record(offset, length, file_number)
            page = following
        return records

    def payload(self, record):
        with self.paths[record.file_number].open("rb") as stream:
            stream.seek(record.offset)
            data = stream.read(record.length)
        require(len(data) == record.length, "SourceReadFailed", "Truncated tile payload.")
        return data
