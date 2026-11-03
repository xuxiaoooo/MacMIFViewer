import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

import imagecodecs
import numpy as np
import tifffile

from mrxs_probe.layout import ProbeError
from mrxs_probe.probe import inspect, summarize
from mrxs_probe.region import ExperimentalRegionReader


def fixture(root, packed=True, grid_rows=1, *, missing_last=False):
    """Generate a tiny slide with explicit mixed-radix index and known payloads."""
    entry = root / "synthetic.mrxs"
    entry.write_bytes(b"synthetic entry")
    sidecar = entry.with_suffix("")
    sidecar.mkdir()
    # A 3+2+1 layout exercises stream group 2 (root slot 4 at one zoom level).
    groups = ((13, 31, 79), (101, 121, 0), (201, 0, 0)) if packed else ((15000,),)
    mapping = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (2, 0)] if packed else [(0, 0)]
    filter_values = []
    filter_sections = []
    for c, (group, slot) in enumerate(mapping):
        filter_values.append(f"HIER_2_VAL_{c}_SECTION = Channel{c}")
        filter_sections.append(f"""[Channel{c}]
FILTER_NAME = Synthetic {c}
DATA_IN_THIS_FILTER_LEVEL = FilterLevel_{group}
STORING_CHANNEL_NUMBER = {slot}
ZSTACK_STEP_COUNT = 0
""")
    content = f"""[GENERAL]
SLIDE_TYPE = SLIDE_TYPE_FLUORESCENCE
SLIDE_ID = synthetic-test-id
IMAGENUMBER_X = 2
IMAGENUMBER_Y = {grid_rows}
VIMSLIDE_SLIDE_BITDEPTH = {8 if packed else 16}
[HIERARCHICAL]
INDEXFILE = Index.dat
NONHIER_COUNT = 0
HIER_COUNT = 4
HIER_0_NAME = Slide zoom level
HIER_0_COUNT = 1
HIER_0_VAL_0_SECTION = Zoom
HIER_1_NAME = Slide zoom mask level2
HIER_1_COUNT = 2
HIER_1_VAL_0 = ZoomMaskDefault
HIER_1_VAL_1 = ZoomMaskData
HIER_2_NAME = Slide filter level
HIER_2_COUNT = {len(mapping)}
{chr(10).join(filter_values)}
HIER_3_NAME = Microscope focus level
HIER_3_COUNT = 1
HIER_3_VAL_0 = ExtFocusLevel
[DATAFILE]
FILE_COUNT = 1
FILE_0 = Data0000.dat
[Zoom]
DIGITIZER_WIDTH = 16
DIGITIZER_HEIGHT = 16
OVERLAP_X = 0
OVERLAP_Y = 0
IMAGE_CONCAT_FACTOR = 0
IMAGE_FORMAT = {"JPEG" if packed else "JPEG XR"}
MICROMETER_PER_PIXEL_X = 0.4
{chr(10).join(filter_sections)}
"""
    (sidecar / "Slidedat.ini").write_text(content, encoding="utf-8")
    signature = b"01.02synthetic-test-id"
    root_pos = len(signature) + 8
    root_size = 2 * len(mapping) * 4
    nonhier = root_pos + root_size
    data = bytearray(signature + struct.pack("<ii", root_pos, nonhier) + bytes(root_size))
    chunks = bytearray()
    for g, values in enumerate(groups):
        pointer = len(data)
        struct.pack_into("<i", data, root_pos + g * 8, pointer)
        count = 2 * grid_rows - int(missing_last)
        data.extend(struct.pack("<iiii", 0, pointer + 8, count, 0))
        for key in range(count):
            if packed:
                pixels = np.empty((16, 16, 3), dtype=np.uint8)
                pixels[:] = np.array(values) + key
                tile = imagecodecs.jpeg_encode(pixels, level=100, colorspace="RGB", outcolorspace="RGB")
                comment = b"Intel(R) IPP JPEG encoder synthetic fixture"
                segment = b"\xff\xfe" + struct.pack(">H", len(comment) + 2) + comment
                tile = tile[:2] + segment + tile[2:]
            else:
                pixels = np.full((16, 16), values[0] + key, dtype=np.uint16)
                tile = imagecodecs.jpegxr_encode(pixels)
            data.extend(struct.pack("<iiii", key, len(chunks), len(tile), 0))
            chunks.extend(tile)
    (sidecar / "Index.dat").write_bytes(data)
    (sidecar / "Data0000.dat").write_bytes(chunks)
    return entry


class ProbeTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)

    def test_six_channels_and_roi_roundtrip(self):
        entry = fixture(self.root)
        rois = self.root / "rois"
        rois.mkdir()
        report = inspect(entry, rois)
        self.assertEqual(report["read_support_status"], "experimental_tile_samples")
        self.assertEqual(report["metadata_channel_count"], 6)
        self.assertEqual(report["verified_decodable_channel_count"], 6)
        self.assertEqual(report["physical_pixel_size_x_um"], 0.4)
        self.assertIsNone(report["physical_pixel_size_y_um"])
        self.assertIsNone(report["verified_raw_bit_depth"])
        for channel, value in zip(report["channels"], [13, 31, 79, 101, 121, 201], strict=True):
            samples = channel["samples"]
            self.assertEqual({s["tile_index"] for s in samples}, {0, 1})
            self.assertEqual(samples[0]["maximum"], value + samples[0]["tile_index"])
            self.assertEqual(samples[0]["encoded_sample_precision_bits"], 8)
            crop = samples[0]["diagnostic_crop"]
            image = tifffile.imread(rois / crop["file"])
            self.assertEqual(image.dtype, np.uint8)
            self.assertEqual(image.shape, (12, 12))
            self.assertEqual(summarize(image)["sha256"], crop["sha256"])

    @unittest.skipUnless(imagecodecs.JPEGXR.available, "JPEG XR backend unavailable")
    def test_synthetic_jpegxr_preserves_dtype_without_claiming_raw_precision(self):
        report = inspect(fixture(self.root, packed=False))
        self.assertEqual(report["compression_detected"], ["JPEG XR"])
        channel = report["channels"][0]
        self.assertEqual(channel["sample_dtype"], "uint16")
        self.assertIsNone(channel["verified_raw_bit_depth"])
        self.assertGreater(channel["samples"][0]["minimum"], 255)

    def test_region_crosses_four_tiles_with_explicit_reversed_order(self):
        reader = ExperimentalRegionReader(fixture(self.root, grid_rows=2), slot_order="reversed")
        data = reader.read_region(15, 15, 2, 2)
        self.assertEqual(data.shape, (6, 2, 2))
        self.assertEqual(data.dtype, np.uint8)
        expected = np.array([[0, 1], [2, 3]], dtype=np.uint8)
        for channel, value in zip(data, [79, 31, 13, 0, 121, 0], strict=True):
            np.testing.assert_array_equal(channel, value + expected)
        with self.assertRaisesRegex(ProbeError, "inside the candidate"):
            reader.read_region(31, 31, 2, 2)

    def test_region_rejects_missing_tile(self):
        entry = fixture(self.root, grid_rows=2, missing_last=True)
        reader = ExperimentalRegionReader(entry, slot_order="direct")
        with self.assertRaisesRegex(ProbeError, "missing tile"):
            reader.read_region(15, 15, 2, 2)

    def test_region_rejects_overlap(self):
        entry = fixture(self.root)
        ini = entry.with_suffix("") / "Slidedat.ini"
        ini.write_text(ini.read_text().replace("OVERLAP_X = 0", "OVERLAP_X = 2"))
        with self.assertRaisesRegex(ProbeError, "without overlap"):
            ExperimentalRegionReader(entry, slot_order="direct")

    def test_missing_data_file(self):
        entry = fixture(self.root)
        (entry.with_suffix("") / "Data0000.dat").unlink()
        report = inspect(entry)
        self.assertFalse(report["file_layout_valid"])
        self.assertEqual(report["unsupported_reasons"][0]["code"], "MissingSourceFile")

    def test_bad_index_signature(self):
        entry = fixture(self.root)
        index = entry.with_suffix("") / "Index.dat"
        index.write_bytes(b"99.99" + index.read_bytes()[5:])
        report = inspect(entry)
        self.assertEqual(report["unsupported_reasons"][0]["code"], "UnsupportedIndex")

    def test_cycle_does_not_hang(self):
        entry = fixture(self.root)
        index = entry.with_suffix("") / "Index.dat"
        data = bytearray(index.read_bytes())
        root, = struct.unpack_from("<i", data, len(b"01.02synthetic-test-id"))
        ptr, = struct.unpack_from("<i", data, root)
        page = ptr + 8
        struct.pack_into("<i", data, page + 4, page)
        index.write_bytes(data)
        report = inspect(entry)
        self.assertEqual(report["unsupported_reasons"][0]["code"], "CorruptIndex")
        self.assertEqual(report["verified_decodable_channel_count"], 3)

    def test_unsupported_z_stack(self):
        entry = fixture(self.root)
        ini = entry.with_suffix("") / "Slidedat.ini"
        ini.write_text(ini.read_text().replace("ZSTACK_STEP_COUNT = 0", "ZSTACK_STEP_COUNT = 3"))
        report = inspect(entry)
        self.assertEqual(report["unsupported_reasons"][0]["code"], "UnsupportedZStack")

    def test_cli_forbids_sidecar_output_and_redacts_input_paths(self):
        entry = fixture(self.root)
        cmd = [sys.executable, "-m", "mrxs_probe", "inspect", str(entry), "--report"]
        protected = entry.with_suffix("") / "result.json"
        result = subprocess.run([*cmd, str(protected)], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(protected.exists())
        dest = self.root / "report.json"
        result = subprocess.run([*cmd, str(dest)], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        content = dest.read_text()
        self.assertNotIn(str(entry), content)
        self.assertEqual(json.loads(content)["verified_decodable_channel_count"], 6)


if __name__ == "__main__":
    unittest.main()
