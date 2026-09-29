# Copyright 2026 Sergiu Alexandrescu
"""Checks that a downloaded file is a usable station logo and writes it the way RoRadio keeps its logos.

Usage: normalize_logo.py <downloaded file> <output .png> <smallest side in px>

A usable logo decodes as an image, is at least that many pixels on its short side (a 32 px favicon is a blur on a
station tile), is no wider than twice its height or the other way round (a wide og:image is a banner or a photo,
not a logo), and is not blank (fully transparent, or one colour). It is written as a PNG at most 400 px on its
longest side, without metadata. Writes one JSON line: {"ok": true, "width", "height", "sha256"} for the written
file, or {"ok": false, "reason"}. Used by Update-StationLogos.ps1.
"""

import hashlib
import json
import sys
from pathlib import Path

from PIL import Image, UnidentifiedImageError

MAX_SIDE = 400
MAX_ASPECT = 2.0
# The 5 MB download cap says nothing about the decoded size: a small compressed file can declare a huge canvas.
# The header's size is checked against this before anything is decoded (Copilot, RoRadioResources#2).
MAX_SOURCE_PIXELS = 4096 * 4096
ARGUMENTS = 4


def has_alpha(image: Image.Image) -> bool:
    """Whether the image carries transparency (an alpha channel, or a transparent palette entry)."""
    return image.mode in ("RGBA", "LA", "PA") or (image.mode == "P" and "transparency" in image.info)


def size_problem(width: int, height: int, min_side: int) -> str | None:
    """Why an image of this size is not a logo, from its header alone; None when the size is fine."""
    if width * height > MAX_SOURCE_PIXELS:
        return f"too large to decode ({width}x{height})"
    if min(width, height) < min_side:
        return f"too small ({width}x{height})"
    if max(width, height) > MAX_ASPECT * min(width, height):
        return f"not logo-shaped ({width}x{height})"
    return None


def blank_problem(image: Image.Image) -> str | None:
    """Why a decoded image shows nothing; None when it has something to show."""
    if image.mode == "RGBA" and image.getchannel("A").getextrema()[1] == 0:
        return "blank (fully transparent)"
    if image.getcolors(maxcolors=1) is not None:
        return "blank (one colour)"
    return None


def normalize(source: str, target: str, min_side: int) -> dict:
    """Check the image at source and, when it is a usable logo, write it to target as RoRadio keeps logos."""
    try:
        with Image.open(source) as opened:
            # Opening reads only the header: the size is judged before a single pixel is decoded.
            problem = size_problem(*opened.size, min_side)
            if problem:
                return {"ok": False, "reason": problem}
            # An .ico holds several sizes; Pillow opens the largest. An animated image keeps its first frame.
            opened.seek(0)
            opened.load()
            image = opened.convert("RGBA" if has_alpha(opened) else "RGB")
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as error:
        return {"ok": False, "reason": f"not an image ({type(error).__name__})"}

    problem = blank_problem(image)
    if problem:
        return {"ok": False, "reason": problem}

    image.thumbnail((MAX_SIDE, MAX_SIDE), Image.Resampling.LANCZOS)
    image.save(target, "PNG", optimize=True)
    digest = hashlib.sha256(Path(target).read_bytes()).hexdigest()
    return {"ok": True, "width": image.width, "height": image.height, "sha256": digest}


def main() -> int:
    """Command line entry point: one JSON line on stdout, exit code 2 on wrong arguments."""
    if len(sys.argv) != ARGUMENTS:
        sys.stderr.write(__doc__ or "")
        return 2
    sys.stdout.write(json.dumps(normalize(sys.argv[1], sys.argv[2], int(sys.argv[3]))) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
