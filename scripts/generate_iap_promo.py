#!/usr/bin/env python3
"""Build the In-App Purchase promotional image.

App Store Connect requires exactly 1024x1024, JPG or PNG, 72 dpi, RGB, flattened
and with no rounded corners — an app screenshot in that field is rejected on size.
The logo is lifted from the 1024 app icon so the two stay in step.

    python3 scripts/generate_iap_promo.py
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
LOGO = ROOT / "store_assets/logo_source.png"
OUT = ROOT / "store_assets/iap_promo_1024.png"

SIZE = 1024
# Flat, and identical to the logo art's own background, so the pasted glyph has
# no seam. A gradient here would show the artwork's square edge.
BG = (11, 18, 32)
ACCENT = (45, 226, 184)
MUTED = (138, 152, 175)


def logo() -> Image.Image:
    """The gauge glyph, trimmed to its bounds."""
    art = Image.open(LOGO).convert("RGB")
    px = art.load()
    minx, miny, maxx, maxy = art.width, art.height, 0, 0
    for y in range(art.height):
        for x in range(art.width):
            if sum(abs(c - b) for c, b in zip(px[x, y], BG)) > 18:
                minx, maxx = min(minx, x), max(maxx, x)
                miny, maxy = min(miny, y), max(maxy, y)
    return art.crop((minx, miny, maxx, maxy))


def main() -> None:
    canvas = Image.new("RGB", (SIZE, SIZE), BG)
    draw = ImageDraw.Draw(canvas)

    glyph = logo()
    target_w = 470
    glyph = glyph.resize((target_w, round(glyph.height * target_w / glyph.width)), Image.LANCZOS)
    canvas.paste(glyph, ((SIZE - glyph.width) // 2, 262))

    bold = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 132, index=0)
    medium = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 40, index=5)

    def centred(text: str, font: ImageFont.FreeTypeFont, y: int, fill, tracking: int = 0) -> None:
        widths = [draw.textlength(ch, font=font) for ch in text]
        total = sum(widths) + tracking * (len(text) - 1)
        x = (SIZE - total) / 2
        for ch, w in zip(text, widths):
            draw.text((x, y), ch, font=font, fill=fill)
            x += w + tracking

    centred("PRO", bold, 640, ACCENT, tracking=14)
    centred("IONIQ TELEMETRY", medium, 812, MUTED, tracking=10)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(OUT, "PNG", dpi=(72, 72))
    print(f"wrote {OUT.relative_to(ROOT)} {canvas.size} mode={canvas.mode}")


if __name__ == "__main__":
    main()
