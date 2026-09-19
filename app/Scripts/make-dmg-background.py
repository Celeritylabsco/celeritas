#!/usr/bin/env python3
"""Draw the picture behind the disk image window.

    ./Scripts/make-dmg-background.py

Writes Resources/dmg-background.png and @2x, then a two-page TIFF that Finder
reads as one retina image. The TIFF is the file make-dmg.sh installs.

The window is 660 by 400 and the background maps to it one pixel per point, so
every coordinate below is also a Finder coordinate. The two icon positions here
have to match the ones in make-dmg.sh or the arrow points at nothing.

Ink and paper carry the words. Cobalt is the arrow and the block in the mark,
which is the only colour in the picture and carries no text.
"""
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont
from fontTools.ttLib import TTFont

HERE = Path(__file__).resolve().parent.parent
FONT_SRC = HERE / "Resources" / "fonts" / "archivo-latin.woff2"
OUT = HERE / "Resources"

INK = (26, 25, 25)
PAPER = (244, 241, 234)
COBALT = (0, 71, 171)

W, H = 660, 400

# Kept short on purpose: it has to fit between the margins at 11.5 points, and
# the assertion at the end of render() fails the build if it stops fitting.
NOTE = "Not signed by Apple. If macOS blocks it: System Settings, Privacy & Security, Open Anyway."

# Icon centres, shared with make-dmg.sh.
APP_X, APP_Y = 180, 160
DEST_X, DEST_Y = 480, 160


def ink(alpha):
    """Ink over paper at a given opacity, flattened, because the background
    has to be a plain image with no transparency for Finder to accept it."""
    return tuple(round(i * alpha + p * (1 - alpha)) for i, p in zip(INK, PAPER))


def load_font(ttf, size, weight=400, width=100):
    font = ImageFont.truetype(str(ttf), size)
    font.set_variation_by_axes([weight, width])
    return font


def words(draw, x, y, text, font, fill, size, measure=False):
    """Draw a line word by word.

    The space in this subset of Archivo is 0.2em, and Pillow rounds every
    advance to a whole pixel, so at 17 points the gap comes out 3 pixels and
    the words run together. Setting the gap here instead fixes it.
    """
    gap = size * 0.27
    total = sum(font.getlength(word) for word in text.split(" ")) + gap * (len(text.split(" ")) - 1)
    if measure:
        return total
    for word in text.split(" "):
        draw.text((x, y), word, font=font, fill=fill, anchor="lm")
        x += font.getlength(word) + gap
    return total


def centre(draw, y, text, font, fill, size, scale):
    """Centre on the image, which is W * scale wide. Using W here instead put
    every centred line a quarter of the way across the retina page."""
    width = words(draw, 0, 0, text, font, fill, size, measure=True)
    words(draw, (W * scale - width) / 2, y, text, font, fill, size)
    return width


def mark(draw, x, y, size):
    """The lab mark: two ink brackets around a cobalt block, from mark.svg on
    the site. Drawn rather than loaded so it stays sharp at 20 points."""
    u = size / 100
    def box(a, b, w, h, fill):
        draw.rectangle([x + a * u, y + b * u, x + (a + w) * u - 1, y + (b + h) * u - 1], fill=fill)
    for a, b, w, h in [(17, 20, 9, 60), (17, 20, 21, 9), (17, 71, 21, 9),
                       (74, 20, 9, 60), (62, 20, 21, 9), (62, 71, 21, 9)]:
        box(a, b, w, h, INK)
    box(42, 41, 16, 18, COBALT)


def arrow(draw, x0, x1, y, weight):
    """The site's arrow, straight and flat. A curved one would be the only
    curve anywhere in the brand."""
    draw.line([(x0, y), (x1, y)], fill=COBALT, width=weight)
    head = 13 * weight / 2
    draw.line([(x1 - head, y - head), (x1, y)], fill=COBALT, width=weight)
    draw.line([(x1 - head, y + head), (x1, y)], fill=COBALT, width=weight)


def render(ttf, scale):
    s = scale
    image = Image.new("RGB", (W * s, H * s), PAPER)
    draw = ImageDraw.Draw(image)

    mark(draw, 44 * s, 30 * s, 25 * s)
    draw.text((80 * s, 42 * s), "Celeritas",
              font=load_font(ttf, round(16 * s), weight=600, width=96), fill=INK, anchor="lm")

    arrow(draw, 276 * s, 384 * s, APP_Y * s, 2 * s)

    centre(draw, 278 * s, "Drag Celeritas into Applications",
           load_font(ttf, round(17 * s), weight=500), INK, 17 * s, s)

    # The honest part. Somebody reading this window is about ten seconds away
    # from the dialog that refuses to open the app, and this is the last
    # surface they look at before it happens.
    draw.line([(44 * s, 322 * s), (616 * s, 322 * s)], fill=ink(0.14), width=1 * s)
    note = centre(draw, 344 * s, NOTE, load_font(ttf, round(11.5 * s), weight=400), ink(0.58), 11.5 * s, s)
    assert note <= (W - 88) * s, f"the note is {note / s:.0f} points wide and runs out of the window"

    return image


def main():
    if not FONT_SRC.exists():
        sys.exit(f"no font at {FONT_SRC}")

    ttf = OUT / "fonts" / "archivo-latin.ttf"
    font = TTFont(str(FONT_SRC))
    font.flavor = None
    font.save(str(ttf))

    one = OUT / "dmg-background.png"
    two = OUT / "dmg-background@2x.png"
    render(ttf, 1).save(one)
    render(ttf, 2).save(two)
    ttf.unlink()

    # tiffutil pairs the two as one image with a retina representation, which
    # is the only way Finder shows a sharp background on a retina display.
    tiff = OUT / "dmg-background.tiff"
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(tiff)],
                   check=True, capture_output=True)

    for path in (one, two, tiff):
        print(f"  {path.relative_to(HERE)}  {path.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
