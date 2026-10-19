"""Draws media/hero.png (the README's top image) and media/social_preview.png (GitHub's social
preview) from the three screenshots and media/icon.png.

    python3 media/tools/make_banners.py media

The screenshots must be 1280x720 and taken from one camera (media/README.md says how), so the
diagonal slices line up. Needs Pillow and the DejaVu fonts.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

MEDIA = sys.argv[1]
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
BG = (31, 42, 68)  # #1f2a44, the icon's backdrop
TAGLINE = "Nanite-style seamless LOD for large meshes in Godot"

shots = [Image.open(f"{MEDIA}/screenshot_{n}.png").convert("RGB")
         for n in ("material", "cluster", "levels")]
W, H = shots[0].size
SLANT = 120  # horizontal run of each dividing line, top to bottom


def slices():
    """The three screenshots in vertical thirds with slanted borders."""
    out = shots[0].copy()
    for i, shot in enumerate(shots[1:], start=1):
        x = W * i / 3
        mask = Image.new("L", (W, H), 0)
        ImageDraw.Draw(mask).polygon(
            [(x + SLANT / 2, 0), (W, 0), (W, H), (x - SLANT / 2, H)], fill=255)
        out.paste(shot, (0, 0), mask)
    d = ImageDraw.Draw(out)
    for i in (1, 2):
        x = W * i / 3
        d.line([(x + SLANT / 2, 0), (x - SLANT / 2, H)], fill=BG, width=4)
    return out


def label(img, text, x, y, size=26):
    d = ImageDraw.Draw(img, "RGBA")
    f = ImageFont.truetype(FONT, size)
    l, t, r, b = d.textbbox((x, y), text, font=f)
    d.rounded_rectangle((l - 12, t - 8, r + 12, b + 8), radius=8, fill=BG + (215,))
    d.text((x, y), text, font=f, fill=(255, 255, 255))


# Hero: 1280x720, a label centered at the bottom of each slice.
hero = slices()
for i, text in enumerate(("Materials", "Clusters", "LOD levels")):
    f = ImageFont.truetype(FONT, 26)
    w = ImageDraw.Draw(hero).textlength(text, font=f)
    cx = W * (2 * i + 1) / 6 - SLANT / 6
    label(hero, text, cx - w / 2, H - 58)
hero.save(f"{MEDIA}/hero.png", optimize=True)

# Social preview: 1280x640, a title band above a strip of the slices (the skyline kept).
social = Image.new("RGB", (1280, 640), BG)
social.paste(slices().crop((0, 110, W, 540)), (0, 210))
d = ImageDraw.Draw(social, "RGBA")
icon = Image.open(f"{MEDIA}/icon.png").convert("RGBA").resize((150, 150), Image.LANCZOS)
social.paste(icon, (48, 30), icon)
d.text((228, 38), "Godotite", font=ImageFont.truetype(FONT, 76), fill=(255, 255, 255))
d.text((232, 135), TAGLINE, font=ImageFont.truetype(FONT_REG, 34), fill=(200, 212, 235))
social.convert("RGB").save(f"{MEDIA}/social_preview.png", optimize=True)
