#!/usr/bin/env python3
"""Compare swift-exif with ExifTool and ffprobe on local media corpora.

The default scan is intentionally non-recursive.  The historical parity corpus
was made from files at the roots of TestImages and TestVideo; their nested
directories now contain a much larger collection of multi-gigabyte originals.
Pass --recursive when that larger (and slower) audit is wanted.

The comparison is contract based.  ExifTool exposes many maker-note fields that
SwiftMediaMetadata does not claim to support, and ffprobe exposes decoder-level
details that are not available from container metadata.  Only the mappings
below count toward the parity result.
"""

from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Iterable


IMAGE_EXTENSIONS = {
    "jpg", "jpeg", "tif", "tiff", "dng", "cr2", "cr3", "nef", "nrw",
    "arw", "raf", "rw2", "orf", "pef", "srw", "raw", "jxl", "png",
    "avif", "heic", "heif", "webp", "gif", "bmp", "dib", "svg", "psd",
    "pdf",
}
VIDEO_EXTENSIONS = {
    "mp4", "mov", "m4v", "mxf", "mkv", "webm", "avi", "mpg", "mpeg",
    "vob", "ts", "m2ts", "mts", "braw", "r3d", "crm", "crl", "ivf",
    "mp3", "flac", "m4a", "ogg", "oga", "opus",
}

# canonical name: (swift-exif keys, ExifTool keys).  ExifTool's -G1 names are
# used so identically named fields from different IFDs remain unambiguous.
IMAGE_FIELDS: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "ImageWidth": (
        ("File:ImageWidth",), ("File:ImageWidth", "IFD0:ImageWidth"),
    ),
    "ImageHeight": (
        ("File:ImageHeight",), ("File:ImageHeight", "IFD0:ImageHeight"),
    ),
    "Make": (("EXIF:Make",), ("IFD0:Make",)),
    "Model": (("EXIF:Model",), ("IFD0:Model",)),
    "Software": (("EXIF:Software",), ("IFD0:Software",)),
    "Orientation": (("EXIF:Orientation",), ("IFD0:Orientation",)),
    "ModifyDate": (("EXIF:DateTime",), ("IFD0:ModifyDate",)),
    "CreateDate": (("EXIF:DateTimeDigitized",), ("ExifIFD:CreateDate",)),
    "DateTimeOriginal": (
        ("EXIF:DateTimeOriginal",), ("ExifIFD:DateTimeOriginal",),
    ),
    "ExposureTime": (("EXIF:ExposureTime",), ("ExifIFD:ExposureTime",)),
    "FNumber": (("EXIF:FNumber",), ("ExifIFD:FNumber",)),
    "ExposureProgram": (
        ("EXIF:ExposureProgram",), ("ExifIFD:ExposureProgram",),
    ),
    "ISO": (("EXIF:ISO",), ("ExifIFD:ISO",)),
    "FocalLength": (("EXIF:FocalLength",), ("ExifIFD:FocalLength",)),
    "FocalLengthIn35mmFormat": (
        ("EXIF:FocalLengthIn35mmFilm",),
        ("ExifIFD:FocalLengthIn35mmFormat",),
    ),
    "LensMake": (("EXIF:LensMake",), ("ExifIFD:LensMake",)),
    "LensModel": (("EXIF:LensModel",), ("ExifIFD:LensModel",)),
    "Flash": (("EXIF:Flash",), ("ExifIFD:Flash",)),
    "MeteringMode": (("EXIF:MeteringMode",), ("ExifIFD:MeteringMode",)),
    "ExposureMode": (("EXIF:ExposureMode",), ("ExifIFD:ExposureMode",)),
    "WhiteBalance": (("EXIF:WhiteBalance",), ("ExifIFD:WhiteBalance",)),
    "PixelXDimension": (
        ("EXIF:PixelXDimension",), ("ExifIFD:ExifImageWidth",),
    ),
    "PixelYDimension": (
        ("EXIF:PixelYDimension",), ("ExifIFD:ExifImageHeight",),
    ),
    "GPSLatitude": (
        ("GPS:GPSLatitude", "EXIF:GPSLatitude"), ("GPS:GPSLatitude",),
    ),
    "GPSLongitude": (
        ("GPS:GPSLongitude", "EXIF:GPSLongitude"), ("GPS:GPSLongitude",),
    ),
    "GPSAltitude": (
        ("GPS:GPSAltitude", "EXIF:GPSAltitude"), ("GPS:GPSAltitude",),
    ),
    "Title": (("XMP-dc:Title",), ("XMP-dc:Title",)),
    "Description": (("XMP-dc:Description",), ("XMP-dc:Description",)),
    "Subject": (("XMP-dc:Subject",), ("XMP-dc:Subject",)),
    "Headline": (("XMP-photoshop:Headline",), ("XMP-photoshop:Headline",)),
    "Credit": (("XMP-photoshop:Credit",), ("XMP-photoshop:Credit",)),
    "ICCDescription": (
        ("ICCProfile:Description",),
        ("ICC_Profile:ProfileDescription", "ICC_Profile:ProfileDescriptionML"),
    ),
}

# swift-exif stream key: ffprobe path.  A tuple means try each ffprobe path.
STREAM_FIELDS: dict[str, tuple[str, ...]] = {
    "StreamType": ("codec_type",),
    "CodecShort": ("codec_name",),
    "Profile": ("profile",),
    "Width": ("width",),
    "Height": ("height",),
    "DisplayAspectRatio": ("display_aspect_ratio",),
    "PixelFormat": ("pix_fmt",),
    "BitDepth": ("bits_per_raw_sample", "bits_per_sample"),
    "BitRate": ("bit_rate",),
    "AvgFrameRate": ("avg_frame_rate",),
    "RFrameRate": ("r_frame_rate",),
    "Duration": ("duration",),
    "FieldOrder": ("field_order",),
    "ChromaLocation": ("chroma_location",),
    "SampleRate": ("sample_rate",),
    "Channels": ("channels",),
    "ChannelLayout": ("channel_layout",),
    "IsAttachedPic": ("disposition.attached_pic",),
    "IsDefault": ("disposition.default",),
    "IsForced": ("disposition.forced",),
    "Timecode": ("tags.timecode",),
    "Title": ("tags.title",),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--images", type=Path, help="still-image corpus root")
    parser.add_argument("--videos", type=Path, help="video/audio corpus root")
    parser.add_argument(
        "--swift-exif", type=Path, default=Path(".build/debug/swift-exif"),
        help="path to the built swift-exif executable",
    )
    parser.add_argument("--exiftool", default="exiftool")
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--recursive", action="store_true")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--json-output", type=Path)
    return parser.parse_args()


def discover(root: Path, extensions: set[str], recursive: bool) -> list[Path]:
    iterator: Iterable[Path] = root.rglob("*") if recursive else root.iterdir()
    return sorted(
        (path for path in iterator if path.is_file()
         and path.suffix.lower().lstrip(".") in extensions),
        key=lambda path: str(path).casefold(),
    )


def run_json(command: list[str], timeout: int) -> Any:
    completed = subprocess.run(
        command, check=False, capture_output=True, text=True, timeout=timeout,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        raise RuntimeError(f"exit {completed.returncode}: {detail}")
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"invalid JSON: {error}") from error


def tool_version(command: list[str]) -> str:
    completed = subprocess.run(
        command, check=False, capture_output=True, text=True, timeout=15,
    )
    output = completed.stdout.strip() or completed.stderr.strip()
    return output.splitlines()[0] if output else "unknown"


def first_value(record: dict[str, Any], keys: Iterable[str]) -> Any:
    for key in keys:
        if key in record:
            return record[key]
    return None


def nested_value(record: dict[str, Any], path: str) -> Any:
    value: Any = record
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            return None
        value = value[component]
    return value


def first_nested_value(record: dict[str, Any], paths: Iterable[str]) -> Any:
    for path in paths:
        value = nested_value(record, path)
        if value is not None and value not in ("0/0", "N/A", ""):
            return value
    return None


def number(value: Any) -> float | None:
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    if not isinstance(value, str):
        return None
    text = value.strip().lower()
    if text == "true":
        return 1.0
    if text == "false":
        return 0.0
    rational = re.fullmatch(r"(-?[0-9.]+)\s*/\s*(-?[0-9.]+)", text)
    if rational:
        denominator = float(rational.group(2))
        return float(rational.group(1)) / denominator if denominator else None
    try:
        return float(text)
    except ValueError:
        return None


def comparable(value: Any) -> Any:
    if isinstance(value, list):
        return sorted(comparable(item) for item in value)
    if isinstance(value, str):
        return " ".join(value.strip().split())
    return value


def equal(left: Any, right: Any) -> bool:
    left_number = number(left)
    right_number = number(right)
    if left_number is not None and right_number is not None:
        return math.isclose(left_number, right_number, rel_tol=1e-4, abs_tol=1e-4)
    return comparable(left) == comparable(right)


def equal_image_field(field: str, left: Any, right: Any) -> bool:
    # The CLI's numeric image path stringifies arrays for display.  ExifTool's
    # JSON retains them as arrays, so restore that shape for Bag-like fields.
    if field == "Subject":
        if isinstance(left, str) and isinstance(right, list):
            left = [item.strip() for item in left.split(",")]
        if isinstance(right, str) and isinstance(left, list):
            right = [item.strip() for item in right.split(",")]
    return equal(left, right)


def issue(field: str, swift: Any, reference: Any) -> dict[str, Any]:
    if swift is None:
        kind = "missing-swift"
    elif reference is None:
        kind = "missing-reference"
    else:
        kind = "mismatch"
    return {"field": field, "kind": kind, "swift": swift, "reference": reference}


def compare_image(path: Path, args: argparse.Namespace) -> dict[str, Any]:
    swift_rows = run_json([
        str(args.swift_exif), "read", str(path), "--format", "json",
        "--show-groups", "--numeric",
    ], args.timeout)
    exif_rows = run_json([
        args.exiftool, "-json", "-G1", "-n", str(path),
    ], args.timeout)
    swift = swift_rows[0]
    reference = exif_rows[0]
    issues = []
    compared = 0
    for field, (swift_keys, reference_keys) in IMAGE_FIELDS.items():
        swift_value = first_value(swift, swift_keys)
        reference_value = first_value(reference, reference_keys)
        if swift_value is None and reference_value is None:
            continue
        # Some RAW parsers derive full-resolution dimensions that ExifTool
        # does not publish under the comparable File/IFD0 keys.  Extra Swift
        # coverage is useful, but it is not a parity gap.
        if reference_value is None:
            continue
        compared += 1
        if not equal_image_field(field, swift_value, reference_value):
            issues.append(issue(field, swift_value, reference_value))
    return {"file": str(path), "compared": compared, "issues": issues}


def stream_codec_fallback(stream: dict[str, Any]) -> Any:
    return stream.get("Codec") if stream.get("StreamType") == "data" else None


def compare_video(path: Path, args: argparse.Namespace) -> dict[str, Any]:
    swift_rows = run_json([
        str(args.swift_exif), "read", str(path), "--format", "json", "--streams",
    ], args.timeout)
    reference = run_json([
        args.ffprobe, "-v", "error", "-show_format", "-show_streams",
        "-show_chapters", "-of", "json", str(path),
    ], args.timeout)
    swift = swift_rows[0]
    swift_streams = swift.get("streams", [])
    reference_streams = reference.get("streams", [])
    issues: list[dict[str, Any]] = []
    compared = 1
    if len(swift_streams) != len(reference_streams):
        issues.append(issue("StreamCount", len(swift_streams), len(reference_streams)))

    for index in range(max(len(swift_streams), len(reference_streams))):
        if index >= len(swift_streams):
            issues.append(issue(f"streams[{index}]", None, reference_streams[index]))
            continue
        if index >= len(reference_streams):
            issues.append(issue(f"streams[{index}]", swift_streams[index], None))
            continue
        swift_stream = swift_streams[index]
        reference_stream = reference_streams[index]
        reference_type = reference_stream.get("codec_type")
        required = {"StreamType", "CodecShort"}
        if reference_type == "video":
            required.update({"Width", "Height", "PixelFormat"})
        elif reference_type == "audio":
            required.update({"SampleRate", "Channels", "ChannelLayout"})
        for swift_key, reference_paths in STREAM_FIELDS.items():
            swift_value = swift_stream.get(swift_key)
            reference_value = first_nested_value(reference_stream, reference_paths)
            if swift_key == "BitDepth" and number(reference_value) == 0:
                reference_value = None
            if swift_value is None and reference_value is None:
                continue
            # An absent false disposition is equivalent to false.  Only a
            # positive reference flag requires Swift to emit the field.
            if swift_key in {"IsAttachedPic", "IsForced"}:
                if number(reference_value) == 0 and swift_value is None:
                    continue
            reference_requires_value = swift_key in required or (
                swift_key in {"Timecode", "Title"} and reference_value is not None
            ) or (
                swift_key in {"IsAttachedPic", "IsForced"}
                and number(reference_value) == 1
            )
            # Extra derived Swift fields and optional ffprobe fields do not
            # represent parity gaps when the other tool omits them.
            if reference_value is None:
                continue
            if swift_value is None and not reference_requires_value:
                continue
            compared += 1
            if not equal(swift_value, reference_value):
                issues.append(issue(
                    f"streams[{index}].{swift_key}", swift_value, reference_value,
                ))

        if swift_stream.get("StreamType") == "data":
            swift_value = stream_codec_fallback(swift_stream)
            reference_value = reference_stream.get("codec_tag_string")
            compared += 1
            if not equal(swift_value, reference_value):
                issues.append(issue(
                    f"streams[{index}].Codec", swift_value, reference_value,
                ))

    swift_format = swift.get("format", {})
    reference_format = reference.get("format", {})
    format_fields = {
        "Duration": "duration",
        "BitRate": "bit_rate",
        "FormatLongName": "format_long_name",
    }
    for swift_key, reference_key in format_fields.items():
        swift_value = swift_format.get(swift_key)
        reference_value = reference_format.get(reference_key)
        if swift_value is None and reference_value is None:
            continue
        compared += 1
        if not equal(swift_value, reference_value):
            issues.append(issue(f"format.{swift_key}", swift_value, reference_value))

    swift_chapters = swift.get("chapters", [])
    reference_chapters = reference.get("chapters", [])
    compared += 1
    if len(swift_chapters) != len(reference_chapters):
        issues.append(issue("ChapterCount", len(swift_chapters), len(reference_chapters)))
    return {"file": str(path), "compared": compared, "issues": issues}


def audit(paths: list[Path], compare: Any, args: argparse.Namespace) -> dict[str, Any]:
    results = []
    errors = []
    for index, path in enumerate(paths, start=1):
        print(f"[{index}/{len(paths)}] {path.name}", file=sys.stderr, flush=True)
        try:
            results.append(compare(path, args))
        except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
            errors.append({"file": str(path), "error": str(error)})
    return {
        "files": len(paths),
        "clean": sum(not result["issues"] for result in results),
        "issues": sum(len(result["issues"]) for result in results),
        "errors": errors,
        "results": results,
    }


def main() -> int:
    args = parse_args()
    if not args.images and not args.videos:
        raise SystemExit("pass --images, --videos, or both")
    if not args.swift_exif.is_file() or not os.access(args.swift_exif, os.X_OK):
        raise SystemExit(f"swift-exif is not executable: {args.swift_exif}")

    report: dict[str, Any] = {
        "scope": "recursive" if args.recursive else "top-level",
        "tools": {
            "swift-exif": tool_version([str(args.swift_exif), "--version"]),
            "exiftool": tool_version([args.exiftool, "-ver"]),
            "ffprobe": tool_version([args.ffprobe, "-version"]),
        },
        "contract": {
            "imageFields": list(IMAGE_FIELDS),
            "streamFields": list(STREAM_FIELDS),
        },
    }
    if args.images:
        paths = discover(args.images, IMAGE_EXTENSIONS, args.recursive)
        report["images"] = audit(paths, compare_image, args)
    if args.videos:
        paths = discover(args.videos, VIDEO_EXTENSIONS, args.recursive)
        report["videos"] = audit(paths, compare_video, args)

    output = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False)
    if args.json_output:
        args.json_output.write_text(output + "\n", encoding="utf-8")
    print(output)

    errors = sum(len(report[k]["errors"]) for k in ("images", "videos") if k in report)
    return 2 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
