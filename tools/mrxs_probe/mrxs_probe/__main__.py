import argparse
import json
from pathlib import Path
import sys

from .probe import inspect


def main():
    parser = argparse.ArgumentParser(description="Read-only MRXS compatibility probe.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("inspect", help="Inspect a slide and sample indexed tiles.")
    command.add_argument("entry", type=Path)
    command.add_argument("--report", type=Path, required=True, help="New JSON file.")
    command.add_argument("--roi-dir", type=Path, help="New private directory for diagnostic TIFF crops.")
    args = parser.parse_args()
    sidecar = args.entry.with_suffix("").resolve()
    destinations = [args.report, args.roi_dir] if args.roi_dir else [args.report]
    for path in destinations:
        resolved = path.resolve()
        inside_source = resolved.is_relative_to(sidecar) or (
            sidecar.is_dir() and any(parent.exists() and parent.samefile(sidecar)
                                     for parent in (resolved, *resolved.parents)))
        if inside_source or resolved == args.entry.resolve():
            parser.error("Output must be outside the source slide.")
        if path.exists() or path.is_symlink():
            parser.error("Output must use a new path.")

    try:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        if args.roi_dir is not None:
            args.roi_dir.mkdir(mode=0o700, parents=True)
        report = inspect(args.entry, args.roi_dir)
        with args.report.open("x", encoding="utf-8") as output:
            json.dump(report, output, indent=2, ensure_ascii=False, allow_nan=False)
            output.write("\n")
    except OSError:
        print("Could not create diagnostic output.", file=sys.stderr)
        return 1
    print(f"{report['read_support_status']}: {report['verified_decodable_channel_count']} channels sampled at level 0")
    errors = [item for item in report["unsupported_reasons"]
              if item["code"] != "ReferenceValidationMissing"]
    return 2 if errors or report["read_support_status"] == "unsupported" else 0


if __name__ == "__main__":
    raise SystemExit(main())
