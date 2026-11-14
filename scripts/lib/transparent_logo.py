# Copyright 2026 Sergiu Alexandrescu
"""Makes a station logo's solid background transparent, and measures how a logo shows on a dark screen.

Usage: transparent_logo.py <logo file> [<logo file> ...]

A logo drawn on a solid background (a white or coloured plate around the mark, filling the image's edges) gets
that background removed: it is flood-filled from the edges, so the same colour inside the mark (white lettering on
a white plate's mark) stays. The edge between the mark and the removed background is softened by its distance
from the background colour, so anti-aliased edges keep no halo. A logo whose edges are not one colour (artwork
that covers its square, a photo) is left as it is: it has no background to remove. Each result is written as a PNG
beside the source (a .jpg becomes a .png of the same name) and one JSON line per file says what was done:
{"logo", "result": "transparent" | "already transparent" | "covers its square", "written"}.

The cast receiver's dark screen (#08090c) shows a transparent logo directly. dark_share() tells how much of a
logo's mark is hard to see there; a logo that is mostly dark gets the receiver's light treatment (receiver.js).
"""

import json
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image

# Two colours this close (Euclidean distance in RGB) are the same background.
TOLERANCE = 40.0
# The share of the edge pixels that must be the background colour for the logo to have a solid background.
SOLID_EDGES = 0.9
# What must remain of a logo once its background is removed: a mark, not a speck or nothing removed at all.
MIN_KEPT = 0.03
MAX_KEPT = 0.95
# A pixel at least this opaque is part of the mark; one at most this opaque is see-through.
OPAQUE = 128
CLEAR = 32
# The receiver's background, and the contrast a mark's pixel needs on it to be seen (WCAG's 3:1 for graphics would
# reject anti-aliased edges, as LogoTone in the app says).
RECEIVER_BACKGROUND = (8, 9, 12)
VISIBLE_CONTRAST = 2.0
# The script's name and at least one logo.
MIN_ARGUMENTS = 2
# Where sRGB's curve turns from linear to the power law (WCAG 2.x).
SRGB_KNEE = 0.03928
# The size every logo is kept under (tests/Helpers.Tests.ps1: every app downloads the ones it does not bundle).
MAX_BYTES = 200 * 1024


def luminance(rgb: np.ndarray) -> np.ndarray:
    """Return the WCAG relative luminance of RGB values (any shape ending in 3), 0-255."""
    c = rgb / 255.0
    c = np.where(c <= SRGB_KNEE, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return 0.2126 * c[..., 0] + 0.7152 * c[..., 1] + 0.0722 * c[..., 2]


def edge_pixels(pixels: np.ndarray) -> np.ndarray:
    """Return the image's outermost ring of pixels, as a list of RGBA values."""
    return np.concatenate([pixels[0], pixels[-1], pixels[1:-1, 0], pixels[1:-1, -1]])


def is_transparent(pixels: np.ndarray) -> bool:
    """Whether the edges are see-through (the logo already has a transparent background).

    Measured over the whole edge, not the corners alone: one stray opaque pixel in a corner (Magic FM, RFI) is not a
    background, and the colour of see-through pixels says nothing (they must never be flood-filled as one).
    """
    return bool((edge_pixels(pixels)[:, 3] <= CLEAR).mean() >= SOLID_EDGES)


def background_of(pixels: np.ndarray) -> np.ndarray | None:
    """Return the solid background colour the image's edges are filled with, or None when they are not one colour."""
    edges = edge_pixels(pixels)[:, :3].astype(float)
    colour = np.median(edges, axis=0)
    same = np.linalg.norm(edges - colour, axis=1) <= TOLERANCE
    return colour if same.mean() >= SOLID_EDGES else None


def flood(distance: np.ndarray) -> np.ndarray:
    """Return the background: every pixel near its colour that the image's edges reach without crossing the mark."""
    height, width = distance.shape
    near = distance <= TOLERANCE
    seen = np.zeros_like(near)
    queue = deque()
    for y in range(height):
        for x in (0, width - 1):
            queue.append((y, x))
    for x in range(width):
        for y in (0, height - 1):
            queue.append((y, x))
    while queue:
        y, x = queue.popleft()
        if 0 <= y < height and 0 <= x < width and near[y, x] and not seen[y, x]:
            seen[y, x] = True
            queue.extend(((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)))
    return seen


def make_transparent(image: Image.Image) -> tuple[Image.Image, str]:
    """Return the logo with its solid background removed, and what was done."""
    pixels = np.array(image.convert("RGBA"))
    if is_transparent(pixels):
        return image, "already transparent"
    colour = background_of(pixels)
    if colour is None:
        return image, "covers its square"
    distance = np.linalg.norm(pixels[..., :3].astype(float) - colour, axis=2)
    background = flood(distance)
    kept = 1 - background.mean()
    if not MIN_KEPT <= kept <= MAX_KEPT:
        return image, "covers its square"
    alpha = pixels[..., 3].astype(float)
    alpha[background] = 0
    # The mark's edge, next to the removed background: as opaque as it is far from the background colour.
    edge = ~background & np.roll(background, 1, 0) | ~background & np.roll(background, -1, 0)
    edge |= ~background & np.roll(background, 1, 1) | ~background & np.roll(background, -1, 1)
    softened = np.clip((distance - TOLERANCE) / TOLERANCE, 0, 1) * 255
    alpha[edge] = np.minimum(alpha[edge], softened[edge])
    pixels[..., 3] = alpha.astype(np.uint8)
    return Image.fromarray(pixels, "RGBA"), "transparent"


def dark_share(image: Image.Image) -> float:
    """Return the share of a logo's mark (its opaque pixels) too dark to see on the receiver's background."""
    pixels = np.array(image.convert("RGBA")).reshape(-1, 4)
    mark = pixels[pixels[:, 3] >= OPAQUE][:, :3].astype(float)
    if len(mark) == 0:
        return 0.0
    background = luminance(np.array(RECEIVER_BACKGROUND, dtype=float))
    contrast = (luminance(mark) + 0.05) / (background + 0.05)
    return float((contrast < VISIBLE_CONTRAST).mean())


def convert(path: Path) -> dict:
    """Make one logo file transparent where it has a solid background; return what was done."""
    with Image.open(path) as opened:
        opened.load()
        image, result = make_transparent(opened)
    written = None
    if result == "transparent":
        target = path.with_suffix(".png")
        image.save(target, "PNG", optimize=True)
        if target.stat().st_size > MAX_BYTES:
            # A photographic logo is large as a full-colour PNG: 256 colours with their transparency keep it small.
            image.quantize(colors=256, method=Image.Quantize.FASTOCTREE).save(target, "PNG", optimize=True)
        if target != path:
            path.unlink()
        written = target.name
    return {"logo": path.name, "result": result, "written": written}


def main() -> int:
    """Command line entry point: one JSON line per logo; exit code 2 without a file."""
    if len(sys.argv) < MIN_ARGUMENTS:
        sys.stderr.write(__doc__ or "")
        return 2
    for name in sys.argv[1:]:
        sys.stdout.write(json.dumps(convert(Path(name))) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
