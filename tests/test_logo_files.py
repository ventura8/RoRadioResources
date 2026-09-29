# Copyright 2026 Sergiu Alexandrescu
"""Every file in RadioLogos decodes completely, as the format its name says (PNG or JPEG)."""

import unittest
from pathlib import Path

from PIL import Image

LOGOS = Path(__file__).resolve().parents[1] / "RadioLogos"
FORMATS = {".png": "PNG", ".jpg": "JPEG", ".jpeg": "JPEG"}


class LogoFilesTest(unittest.TestCase):
    """The logos the apps bundle and GitHub Pages serves are whole images: a magic number is not enough."""

    def test_every_logo_decodes_completely_as_its_extension_says(self) -> None:
        """A truncated or mislabelled file fails here, before an app shows a broken tile."""
        files = sorted(path for path in LOGOS.iterdir() if path.is_file())
        self.assertTrue(files, "RadioLogos is empty")
        for path in files:
            with self.subTest(logo=path.name), Image.open(path) as image:
                self.assertEqual(image.format, FORMATS.get(path.suffix.lower()), "the format the extension names")
                image.load()


if __name__ == "__main__":
    unittest.main()
