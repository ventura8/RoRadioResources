# Copyright 2026 Sergiu Alexandrescu
"""Tests of scripts/lib/normalize_logo.py: which downloads become logos, and how they are written."""

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "lib" / "normalize_logo.py"
_SPEC = importlib.util.spec_from_file_location("normalize_logo", SCRIPT)
normalize_logo = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(normalize_logo)
normalize = normalize_logo.normalize

MIN_SIDE = 128
SHA256_HEX_LENGTH = 64
USAGE_EXIT_CODE = 2


class NormalizeLogoTest(unittest.TestCase):
    """The checks and the output format of normalize()."""

    def setUp(self) -> None:
        """Give each test its own folder."""
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)

    def image(self, name: str, size: tuple[int, int], mode: str = "RGB", *, two_colours: bool = True) -> str:
        """Write a test image: a filled square with a smaller square of another colour inside."""
        image = Image.new(mode, size, (200, 30, 30, 255) if mode == "RGBA" else (200, 30, 30))
        if two_colours:
            inner = (size[0] // 4, size[1] // 4, size[0] // 2, size[1] // 2)
            image.paste((20, 20, 20, 255) if mode == "RGBA" else (20, 20, 20), inner)
        path = self.root / name
        image.save(path)
        return str(path)

    def check(self, source: str, name: str = "out.png") -> dict:
        """Run normalize() on a source with the refresh's smallest side."""
        return normalize(source, str(self.root / name), MIN_SIDE)

    def test_a_large_logo_is_scaled_to_400_px_and_written_as_png(self) -> None:
        """A 1000 px logo comes out 400 px on its longest side, as a PNG."""
        result = self.check(self.image("big.jpg", (1000, 800)))
        self.assertTrue(result["ok"])
        self.assertEqual((result["width"], result["height"]), (400, 320))
        with Image.open(self.root / "out.png") as written:
            self.assertEqual(written.format, "PNG")
            self.assertEqual(written.size, (400, 320))
        self.assertEqual(len(result["sha256"]), SHA256_HEX_LENGTH)

    def test_a_small_logo_keeps_its_size_and_its_transparency(self) -> None:
        """Nothing is scaled up, and an alpha channel survives."""
        result = self.check(self.image("small.png", (200, 200), "RGBA"))
        self.assertTrue(result["ok"])
        with Image.open(self.root / "out.png") as written:
            self.assertEqual(written.size, (200, 200))
            self.assertEqual(written.mode, "RGBA")

    def test_a_favicon_is_too_small(self) -> None:
        """A 32 px icon is a blur on a station tile."""
        result = self.check(self.image("icon.png", (32, 32)))
        self.assertFalse(result["ok"])
        self.assertIn("too small", result["reason"])

    def test_a_banner_is_not_a_logo(self) -> None:
        """A 1200x400 og:image is a banner or a photo."""
        result = self.check(self.image("banner.png", (1200, 400)))
        self.assertFalse(result["ok"])
        self.assertIn("not logo-shaped", result["reason"])

    def test_a_huge_canvas_is_refused_before_it_is_decoded(self) -> None:
        """An image whose header declares more pixels than the limit is not decoded at all."""
        source = self.image("huge.png", (300, 300))
        with (
            mock.patch.object(normalize_logo, "MAX_SOURCE_PIXELS", 200 * 200),
            mock.patch.object(Image.Image, "load", side_effect=AssertionError("decoded")),
        ):
            result = self.check(source)
        self.assertFalse(result["ok"])
        self.assertIn("too large to decode", result["reason"])

    def test_a_blank_image_is_not_a_logo(self) -> None:
        """One colour, or nothing visible at all."""
        plain = self.check(self.image("plain.png", (256, 256), two_colours=False), "a.png")
        self.assertIn("one colour", plain["reason"])
        clear = self.root / "clear.png"
        Image.new("RGBA", (256, 256), (0, 0, 0, 0)).save(clear)
        self.assertIn("fully transparent", self.check(str(clear), "b.png")["reason"])

    def test_a_web_page_is_not_an_image(self) -> None:
        """A site that answers the image url with its HTML page."""
        page = self.root / "page.png"
        page.write_text("<html><body>Not found</body></html>", encoding="utf-8")
        result = self.check(str(page))
        self.assertFalse(result["ok"])
        self.assertIn("not an image", result["reason"])

    def test_the_command_line_writes_one_json_line(self) -> None:
        """Update-StationLogos.ps1 reads the result from stdout; wrong arguments exit with 2."""
        source = self.image("cli.png", (300, 300))
        output = io.StringIO()
        arguments = [str(SCRIPT), source, str(self.root / "cli-out.png"), str(MIN_SIDE)]
        with mock.patch.object(sys, "argv", arguments), contextlib.redirect_stdout(output):
            self.assertEqual(normalize_logo.main(), 0)
        self.assertTrue(json.loads(output.getvalue())["ok"])
        with mock.patch.object(sys, "argv", [str(SCRIPT)]), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(normalize_logo.main(), USAGE_EXIT_CODE)


if __name__ == "__main__":
    unittest.main()
