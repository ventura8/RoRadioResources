# Copyright 2026 Sergiu Alexandrescu
"""Station logos on the cast receiver's dark screen: transparent backgrounds, and marks that can be seen.

The receiver draws a logo directly on its dark background, never on a plate (owner, 2026-11-14): Pro FM's white
"OPEN RADIO" vanished on the white tile the page drew. So every logo either has a transparent background, or is
artwork that covers its square (no solid background to remove); and a logo whose mark is mostly too dark for the
dark screen is one the receiver gives its light treatment, by the same measure (receiver.js).
"""

import importlib.util
import re
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
# scripts/lib is not a package on the path: the module is loaded from its file.
SPEC = importlib.util.spec_from_file_location("transparent_logo", ROOT / "scripts" / "lib" / "transparent_logo.py")
transparent_logo = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transparent_logo)

LOGOS = ROOT / "RadioLogos"
RECEIVER = (ROOT / "receiver" / "receiver.js").read_text(encoding="utf-8")


def square(colour: tuple, size: int = 40, mark: tuple | None = None) -> Image.Image:
    """Return a test logo: a solid square, with a 10 px mark of another colour in its middle."""
    image = Image.new("RGBA", (size, size), colour)
    if mark:
        image.paste(Image.new("RGBA", (10, 10), mark), (15, 15))
    return image


class TransparentLogoTest(unittest.TestCase):
    """make_transparent removes a solid background and nothing else."""

    def test_a_white_plate_goes_and_the_mark_stays(self) -> None:
        """The plate is see-through; the mark keeps its colour and opacity."""
        image, result = transparent_logo.make_transparent(square((255, 255, 255, 255), mark=(200, 0, 0, 255)))
        self.assertEqual(result, "transparent")
        self.assertEqual(image.getpixel((0, 0))[3], 0)
        self.assertEqual(image.getpixel((20, 20)), (200, 0, 0, 255))

    def test_white_inside_the_mark_stays(self) -> None:
        """Only the background the edges reach goes: white lettering inside a mark is kept."""
        logo = square((255, 255, 255, 255), mark=(0, 0, 0, 255))
        logo.paste(Image.new("RGBA", (4, 4), (255, 255, 255, 255)), (18, 18))
        image, _ = transparent_logo.make_transparent(logo)
        self.assertEqual(image.getpixel((19, 19)), (255, 255, 255, 255))

    def test_a_logo_already_transparent_or_covering_its_square_is_left_alone(self) -> None:
        """No background to remove: the edges are see-through, not one colour, or the whole square."""
        clear = square((0, 0, 0, 0), mark=(255, 0, 0, 255))
        self.assertEqual(transparent_logo.make_transparent(clear)[1], "already transparent")
        noise = Image.fromarray(np.random.default_rng(1).integers(0, 255, (40, 40, 4), dtype=np.uint8) | 255)
        self.assertEqual(transparent_logo.make_transparent(noise)[1], "covers its square")
        self.assertEqual(transparent_logo.make_transparent(square((10, 200, 10, 255)))[1], "covers its square")

    def test_dark_share_measures_the_mark_alone(self) -> None:
        """Dark lettering on transparency is all dark; a white mark is none; nothing opaque is none."""
        self.assertEqual(transparent_logo.dark_share(square((0, 0, 0, 0), mark=(20, 20, 20, 255))), 1.0)
        self.assertEqual(transparent_logo.dark_share(square((0, 0, 0, 0), mark=(255, 255, 255, 255))), 0.0)
        self.assertEqual(transparent_logo.dark_share(square((0, 0, 0, 0))), 0.0)

    def test_the_command_line_converts_and_renames_a_jpeg(self) -> None:
        """A .jpg on a plate becomes a transparent .png of the same name; the .jpg is gone."""
        folder = Path(self.id().replace(".", "_"))
        folder.mkdir(exist_ok=True)
        try:
            source = folder / "plate.jpg"
            square((255, 255, 255, 255), mark=(200, 0, 0, 255)).convert("RGB").save(source, "JPEG", quality=100)
            self.assertEqual(
                transparent_logo.convert(source), {"logo": "plate.jpg", "result": "transparent", "written": "plate.png"}
            )
            self.assertFalse(source.exists())
            with Image.open(folder / "plate.png") as written:
                self.assertEqual(written.convert("RGBA").getpixel((0, 0))[3], 0)
        finally:
            for path in folder.iterdir():
                path.unlink()
            folder.rmdir()


class ReceiverLogosTest(unittest.TestCase):
    """Every logo the receiver can show (RadioLogos, served by GitHub Pages) is drawn well on its dark screen."""

    def test_every_logo_has_a_transparent_background_or_covers_its_square(self) -> None:
        """No logo keeps a solid background (alpha at the edges) the receiver would show as a plate."""
        for path in sorted(LOGOS.iterdir()):
            with self.subTest(logo=path.name), Image.open(path) as image:
                self.assertNotEqual(transparent_logo.make_transparent(image)[1], "transparent", "a solid background")

    def test_a_logo_too_dark_for_the_screen_is_one_the_receiver_lights(self) -> None:
        """The receiver's light treatment uses the same measure as this test: its constants are these."""
        share = float(re.search(r"const DARK_SHARE = ([\d.]+);", RECEIVER).group(1))
        contrast = float(re.search(r"const VISIBLE_CONTRAST = ([\d.]+);", RECEIVER).group(1))
        self.assertEqual(contrast, transparent_logo.VISIBLE_CONTRAST)
        readable = 0
        for path in sorted(LOGOS.iterdir()):
            with Image.open(path) as image:
                readable += transparent_logo.dark_share(image) <= share
        # Most logos read as they are; the rest get the receiver's light glow.
        self.assertGreater(readable, len(list(LOGOS.iterdir())) * 0.7)


if __name__ == "__main__":
    unittest.main()
