"""Independent tifffile fixtures and round-trip verification for the macOS reader."""
import json
from pathlib import Path
import sys

import numpy as np
import tifffile


def image(channel, dtype=np.uint16):
    y, x = np.indices((333, 515))
    return ((x * 17 + y * 41 + channel * 1009) % (np.iinfo(dtype).max + 1)).astype(dtype)


def create(root):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools/mrxs_probe/tests"))
    from test_probe import fixture
    fixture(root, grid_rows=2)
    planes = np.stack([image(c) for c in range(6)])
    with tifffile.TiffWriter(root / "six.ome.tiff", ome=True, bigtiff=True, byteorder=">") as writer:
        writer.write(
            planes, photometric="minisblack", tile=(128, 128), compression="deflate",
            subifds=1, metadata={"axes": "CYX", "PhysicalSizeX": 325, "PhysicalSizeXUnit": "nm",
                                 "PhysicalSizeY": 0.5, "PhysicalSizeYUnit": "µm",
                                 "Channel": {"Name": [f"Test {c}" for c in range(6)]}},
        )
        writer.write(planes[:, ::2, ::2], photometric="minisblack", tile=(64, 64),
                     subfiletype=1, compression="deflate", metadata=None)
    tifffile.imwrite(root / "split-01.tiff", image(0, np.uint8), tile=(64, 128),
                     compression="lzw", resolution=(10000, 20000), resolutionunit="CENTIMETER")
    tifffile.imwrite(root / "split-02.tiff", image(1, np.uint8), rowsperstrip=23,
                     compression="deflate", resolution=(10000, 20000), resolutionunit="CENTIMETER")
    tifffile.imwrite(root / "mixed.tiff", image(1), tile=(64, 64))
    tifffile.imwrite(root / "misaligned.tiff", image(1)[:, :-1], tile=(64, 64))
    tifffile.imwrite(root / "rgb.tiff", np.zeros((32, 32, 3), np.uint8), photometric="rgb")
    tifffile.imwrite(root / "jpeg.tiff", image(0, np.uint8), tile=(64, 64), compression="jpeg")
    mappings = '<TiffData IFD="1" FirstC="0"/><TiffData IFD="0" FirstC="1"/>'
    xml = (
        '<OME xmlns="http://www.openmicroscopy.org/Schemas/OME/2016-06"><Image ID="Image:0">'
        '<Pixels ID="Pixels:0" DimensionOrder="XYCZT" Type="uint16" SizeX="515" SizeY="333" '
        'SizeZ="1" SizeT="1" SizeC="2"><Channel ID="Channel:0:0" SamplesPerPixel="1"/>'
        '<Channel ID="Channel:0:1" SamplesPerPixel="1"/>' + mappings + '</Pixels></Image></OME>'
    )
    with tifffile.TiffWriter(root / "reordered.ome.tiff") as writer:
        writer.write(image(0), description=xml, metadata=None)
        writer.write(image(1), metadata=None)


def verify(root):
    for name in ("raw-default", "raw-modified"):
        file = root / name / "raw.ome.tiff"
        with tifffile.TiffFile(file) as tif:
            data = tif.asarray()
            assert tif.series[0].axes == "CYX"
            assert data.dtype == np.uint16 and data.shape == (6, 271, 283)
            assert "PhysicalSizeX=\"0.325\"" in tif.ome_metadata
            assert "PhysicalSizeY=\"0.5\"" in tif.ome_metadata
            for c, plane in enumerate(data):
                np.testing.assert_array_equal(plane, image(c)[62:333, 232:515])
    raw8 = tifffile.imread(root / "raw-8" / "raw.ome.tiff")
    assert raw8.dtype == np.uint8 and raw8.shape == (2, 271, 283)
    np.testing.assert_array_equal(raw8, np.stack([image(c, np.uint8)[62:333, 232:515] for c in range(2)]))
    display = tifffile.imread(root / "rendered" / "rendered.tiff")
    assert display.dtype == np.uint8 and display.shape == (271, 283, 3)
    assert np.any(display[:, :, 0])
    assert not np.any(display[:, :, 1:])
    from imagecodecs import jpeg_decode, png_decode
    png = png_decode((root / "rendered-png" / "rendered.png").read_bytes())
    np.testing.assert_array_equal(display, png[:, :, :3])
    stamped = tifffile.imread(root / "scale-tiff" / "rendered.tiff")
    stamped_png = png_decode((root / "scale-png" / "rendered.png").read_bytes())
    np.testing.assert_array_equal(stamped, stamped_png[:, :, :3])
    np.testing.assert_array_equal(stamped[:200], display[:200])
    assert np.any(np.all(stamped[200:, :100] == 255, axis=-1))
    stamped_info = json.loads((root / "scale-tiff" / "roi.json").read_text())
    assert stamped_info["annotationName"] == "Tissue edge"
    assert stamped_info["calibration"]["source"] == "manual"
    assert stamped_info["renderedScaleBar"] == "20 µm"
    jpeg = jpeg_decode((root / "scale-jpeg" / "rendered.jpeg").read_bytes())
    assert jpeg.shape == stamped.shape and jpeg.dtype == np.uint8
    assert np.mean(np.abs(jpeg.astype(np.int16) - stamped)) < 5
    assert np.any(np.all(jpeg[200:, :100] > 230, axis=-1))
    jpeg_info = json.loads((root / "scale-jpeg" / "roi.json").read_text())
    assert jpeg_info == {**stamped_info, "format": "Rendered JPEG"}
    print("Independent TIFF/PNG/JPEG readback, scale stamp and pixel comparisons passed.")


if __name__ == "__main__":
    root = Path(sys.argv[2])
    {"create": create, "verify": verify}[sys.argv[1]](root)
